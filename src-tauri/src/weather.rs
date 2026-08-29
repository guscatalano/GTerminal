//! Weather and air quality for a postcode, for the status bar.
//!
//! Off unless asked for. The status bar's other items read the machine;
//! this one reaches the network and carries a postcode with it, which is
//! the most identifying thing the app would ever send anywhere. So it is
//! blank by default and nothing is requested until someone types one in -
//! the same rule the optional AI endpoint follows, and PRIVACY.md says so.
//!
//! No API keys, no accounts, and no service of the developer's: a postcode
//! goes to Zippopotam to become coordinates, and those coordinates go to
//! Open-Meteo. Both are free and keyless, which also means there is no
//! identifier tying two requests together.

use serde::{Deserialize, Serialize};

pub const ZIP_API: &str = "https://api.zippopotam.us";
pub const WEATHER_API: &str = "https://api.open-meteo.com/v1/forecast";
pub const AIR_API: &str = "https://air-quality-api.open-meteo.com/v1/air-quality";

/// Where a postcode is.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Place {
    pub name: String,
    pub region: String,
    pub lat: f64,
    pub lon: f64,
}

/// Everything one refresh gathers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub place: String,
    pub temp: f64,
    pub feels_like: f64,
    pub unit: String,
    pub humidity: f64,
    pub wind: f64,
    pub wind_unit: String,
    pub conditions: String,
    /// US AQI, and the EPA band it falls in.
    pub aqi: Option<f64>,
    pub aqi_label: String,
    pub pm2_5: Option<f64>,
    pub pm10: Option<f64>,
    /// When this was fetched, epoch millis, so the UI can say how old it is.
    pub fetched_ms: u64,
}

fn num(v: &serde_json::Value, key: &str) -> Option<f64> {
    let x = v.get(key)?;
    x.as_f64().or_else(|| x.as_str().and_then(|s| s.parse().ok()))
}

/// Zippopotam's answer. Its numbers arrive as strings, which is the sort of
/// thing that silently becomes 0.0 if nobody looks.
pub fn parse_place(json: &str) -> Option<Place> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let first = v.get("places")?.as_array()?.first()?;
    let lat = num(first, "latitude")?;
    let lon = num(first, "longitude")?;
    // A postcode that does not exist comes back without places at all, so
    // reaching here means there is one. Coordinates of exactly 0,0 are in
    // the Atlantic and are what a failed string parse would look like.
    if lat == 0.0 && lon == 0.0 {
        return None;
    }
    Some(Place {
        name: first
            .get("place name")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string(),
        region: first
            .get("state abbreviation")
            .or_else(|| first.get("state"))
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_string(),
        lat,
        lon,
    })
}

/// WMO weather codes, which is what Open-Meteo reports instead of text.
pub fn conditions(code: i64) -> &'static str {
    match code {
        0 => "Clear",
        1 => "Mainly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45 | 48 => "Fog",
        51 | 53 | 55 => "Drizzle",
        56 | 57 => "Freezing drizzle",
        61 => "Light rain",
        63 => "Rain",
        65 => "Heavy rain",
        66 | 67 => "Freezing rain",
        71 => "Light snow",
        73 => "Snow",
        75 => "Heavy snow",
        77 => "Snow grains",
        80 | 81 => "Rain showers",
        82 => "Violent rain showers",
        85 | 86 => "Snow showers",
        95 => "Thunderstorm",
        96 | 99 => "Thunderstorm with hail",
        _ => "—",
    }
}

/// The EPA's bands. The number alone means nothing to most people; "156"
/// and "Unhealthy" are the same fact, and only one of them is readable at
/// a glance in a status bar.
pub fn aqi_label(aqi: f64) -> &'static str {
    match aqi {
        a if a < 0.0 => "—",
        a if a <= 50.0 => "Good",
        a if a <= 100.0 => "Moderate",
        a if a <= 150.0 => "Unhealthy for sensitive groups",
        a if a <= 200.0 => "Unhealthy",
        a if a <= 300.0 => "Very unhealthy",
        _ => "Hazardous",
    }
}

/// Pull the current block out of an Open-Meteo forecast answer.
pub fn parse_current(json: &str) -> Option<serde_json::Value> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v.get("current").cloned()
}

/// Whether a postcode is worth sending anywhere.
///
/// Checked before the request, not after: a stray character in a settings
/// box should not become a network request carrying whatever was typed.
pub fn valid_postcode(zip: &str) -> bool {
    let z = zip.trim();
    !z.is_empty()
        && z.len() <= 10
        && z.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == ' ')
}

/// Two-letter country code for the postcode lookup.
pub fn valid_country(c: &str) -> bool {
    let c = c.trim();
    c.len() == 2 && c.chars().all(|ch| ch.is_ascii_alphabetic())
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(8))
        .timeout(std::time::Duration::from_secs(20))
        .user_agent(concat!("GTerminal/", env!("GTERMINAL_VERSION")))
        .build()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// One refresh: postcode to coordinates, coordinates to weather and air.
pub fn fetch(zip: &str, country: &str, fahrenheit: bool) -> Result<Report, String> {
    if !valid_postcode(zip) {
        return Err("that does not look like a postcode".into());
    }
    if !valid_country(country) {
        return Err("country must be a two-letter code, like us or gb".into());
    }
    let a = agent();
    let place_json = a
        .get(&format!(
            "{ZIP_API}/{}/{}",
            country.trim().to_lowercase(),
            zip.trim()
        ))
        .call()
        .map_err(|_| format!("no such postcode: {}", zip.trim()))?
        .into_string()
        .map_err(|e| format!("could not read the postcode lookup: {e}"))?;
    let place = parse_place(&place_json).ok_or_else(|| format!("no such postcode: {}", zip.trim()))?;

    let (t_unit, w_unit) = if fahrenheit {
        ("fahrenheit", "mph")
    } else {
        ("celsius", "kmh")
    };
    let wx = a
        .get(WEATHER_API)
        .query("latitude", &place.lat.to_string())
        .query("longitude", &place.lon.to_string())
        .query(
            "current",
            "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m",
        )
        .query("temperature_unit", t_unit)
        .query("wind_speed_unit", w_unit)
        .call()
        .map_err(|e| format!("could not reach the weather service: {e}"))?
        .into_string()
        .map_err(|e| format!("could not read the weather: {e}"))?;
    let cur = parse_current(&wx).ok_or("the weather service sent nothing usable")?;

    // Air quality is a second service and a nice-to-have: if it is down,
    // the temperature is still worth showing.
    let air = a
        .get(AIR_API)
        .query("latitude", &place.lat.to_string())
        .query("longitude", &place.lon.to_string())
        .query("current", "us_aqi,pm2_5,pm10")
        .call()
        .ok()
        .and_then(|r| r.into_string().ok())
        .and_then(|s| parse_current(&s));

    let aqi = air.as_ref().and_then(|c| num(c, "us_aqi"));
    Ok(Report {
        place: if place.region.is_empty() {
            place.name.clone()
        } else {
            format!("{}, {}", place.name, place.region)
        },
        temp: num(&cur, "temperature_2m").unwrap_or(f64::NAN),
        feels_like: num(&cur, "apparent_temperature").unwrap_or(f64::NAN),
        unit: if fahrenheit { "°F".into() } else { "°C".into() },
        humidity: num(&cur, "relative_humidity_2m").unwrap_or(f64::NAN),
        wind: num(&cur, "wind_speed_10m").unwrap_or(f64::NAN),
        wind_unit: if fahrenheit { "mph".into() } else { "km/h".into() },
        conditions: conditions(num(&cur, "weather_code").unwrap_or(-1.0) as i64).to_string(),
        aqi,
        aqi_label: aqi.map(aqi_label).unwrap_or("—").to_string(),
        pm2_5: air.as_ref().and_then(|c| num(c, "pm2_5")),
        pm10: air.as_ref().and_then(|c| num(c, "pm10")),
        fetched_ms: now_ms(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coordinates_arrive_as_strings_and_must_still_be_numbers() {
        // Zippopotam sends them quoted. Read with as_f64 alone they are all
        // None, every lookup lands at 0,0 in the Atlantic, and the status
        // bar cheerfully reports the weather there.
        let json = r#"{"places":[{"place name":"Beverly Hills","state abbreviation":"CA","latitude":"34.0901","longitude":"-118.4065"}]}"#;
        let p = parse_place(json).expect("a place");
        assert_eq!(p.name, "Beverly Hills");
        assert_eq!(p.region, "CA");
        assert!((p.lat - 34.0901).abs() < 0.0001);
        assert!((p.lon + 118.4065).abs() < 0.0001);
    }

    #[test]
    fn an_unknown_postcode_is_nothing_not_the_atlantic() {
        assert!(parse_place(r#"{}"#).is_none());
        assert!(parse_place(r#"{"places":[]}"#).is_none());
        assert!(parse_place("not json").is_none());
        // What a failed string parse would look like if one crept back in.
        assert!(parse_place(r#"{"places":[{"latitude":"x","longitude":"y"}]}"#).is_none());
    }

    #[test]
    fn the_epa_bands_are_the_epa_bands() {
        // Boundaries, because these are the values everyone gets wrong by
        // one: 50 is still Good and 51 is not.
        assert_eq!(aqi_label(0.0), "Good");
        assert_eq!(aqi_label(50.0), "Good");
        assert_eq!(aqi_label(51.0), "Moderate");
        assert_eq!(aqi_label(100.0), "Moderate");
        assert_eq!(aqi_label(101.0), "Unhealthy for sensitive groups");
        assert_eq!(aqi_label(150.0), "Unhealthy for sensitive groups");
        assert_eq!(aqi_label(151.0), "Unhealthy");
        assert_eq!(aqi_label(200.0), "Unhealthy");
        assert_eq!(aqi_label(201.0), "Very unhealthy");
        assert_eq!(aqi_label(300.0), "Very unhealthy");
        assert_eq!(aqi_label(301.0), "Hazardous");
    }

    #[test]
    fn weather_codes_read_as_weather() {
        assert_eq!(conditions(0), "Clear");
        assert_eq!(conditions(3), "Overcast");
        assert_eq!(conditions(65), "Heavy rain");
        assert_eq!(conditions(95), "Thunderstorm");
        // An unknown code is a dash, not a panic and not a wrong forecast.
        assert_eq!(conditions(1234), "—");
        assert_eq!(conditions(-1), "—");
    }

    #[test]
    fn nothing_is_sent_for_something_that_is_not_a_postcode() {
        // Checked before the request: a settings box should not turn
        // whatever was typed into a URL.
        assert!(valid_postcode("90210"));
        assert!(valid_postcode("SW1A 1AA"));
        assert!(valid_postcode("K1A-0B1"));
        assert!(!valid_postcode(""));
        assert!(!valid_postcode("   "));
        assert!(!valid_postcode("../../etc/passwd"));
        assert!(!valid_postcode("90210?x=1"));
        assert!(!valid_postcode("this is far too long to be one"));
    }

    #[test]
    fn the_country_is_a_country_code() {
        assert!(valid_country("us"));
        assert!(valid_country("GB"));
        assert!(!valid_country("usa"));
        assert!(!valid_country(""));
        assert!(!valid_country("u1"));
        assert!(!valid_country("../"));
    }

    #[test]
    fn a_forecast_without_a_current_block_is_no_forecast() {
        assert!(parse_current(r#"{"current":{"temperature_2m":71.2}}"#).is_some());
        assert!(parse_current(r#"{"hourly":{}}"#).is_none());
        assert!(parse_current("nope").is_none());
    }
}

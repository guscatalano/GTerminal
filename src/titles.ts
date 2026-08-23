// What a tab is called when the user has not named it.
//
// Pulled out of main.ts so it can be tested: it is a pile of small
// judgements — is this shell-set title worth showing, is the folder the
// home directory, is anything actually running — and every one of them
// is visible on screen, on every tab, all the time.

export const SHELLS = /^(pwsh|powershell|cmd|conhost)$/i;

/// Titles a shell sets for itself that say nothing a user wants on a tab:
/// its own name, or the path it is sitting in, which the folder label
/// already covers.
export const BORING_TITLE =
  /^(Administrator:\s*)?([A-Za-z]:\\[^|—-]*\\)?(pwsh|powershell|cmd)(\.exe)?$|^Windows PowerShell$|^Command Prompt$|^[A-Za-z]:\\\S*$/i;

export interface TitleInputs {
  /// Working directory as the shell last reported it.
  cwd: string;
  /// Process names running in the session, shells included.
  running: string[];
  /// The title the shell set for itself, if any.
  shellTitle: string;
  /// "PowerShell" / "Windows PowerShell" / "Command Prompt".
  shellName: string;
  mode: string;
  template?: string;
}

export function cwdParts(cwd: string): string[] {
  return cwd ? cwd.replace(/[\\/]+$/, "").split(/[\\/]/).filter(Boolean) : [];
}

/// True for C:\Users\<name> exactly. The home directory's leaf is the
/// username, which on every tab at once is no label at all.
export function isHomeDir(parts: string[]): boolean {
  return parts.length === 3 && parts[1].toLowerCase() === "users";
}

/// The first running process that is not itself a shell — what the tab is
/// *doing*, as opposed to what it is.
export function runningProgram(running: string[]): string | undefined {
  return running.find((n) => !SHELLS.test(n));
}

export function autoTitle(i: TitleInputs): { text: string; fromCwd: boolean } {
  const parts = cwdParts(i.cwd);
  const tail = parts[parts.length - 1];
  const home = isHomeDir(parts);
  const prog = runningProgram(i.running);
  const interesting = i.shellTitle && !BORING_TITLE.test(i.shellTitle) ? i.shellTitle : "";
  const dirLabel = () =>
    tail && !home ? { text: tail, fromCwd: true } : { text: i.shellName, fromCwd: false };

  switch (i.mode) {
    case "dir":
      return dirLabel();
    case "program":
      return { text: prog ?? i.shellName, fromCwd: false };
    case "shelltitle":
      return interesting ? { text: interesting, fromCwd: false } : dirLabel();
    case "custom": {
      const vals: Record<string, string> = {
        program: prog ?? "",
        folder: tail && !home ? tail : "",
        parent: parts.length >= 2 ? parts[parts.length - 2] : "",
        path: i.cwd ?? "",
        shell: i.shellName,
        title: interesting,
      };
      const rendered = (i.template ?? "{program} · {folder}")
        .replace(/\{(\w+)\}/g, (_, k: string) => vals[k] ?? "")
        .split("·")
        .map((p) => p.trim())
        .filter(Boolean)
        .join(" · ");
      return rendered
        ? { text: rendered.slice(0, 60), fromCwd: false }
        : { text: i.shellName, fromCwd: false };
    }
    default: {
      // smart: the shell's own title if it said anything useful, else
      // what is running and where, else just where.
      //
      // Note this changes as commands come and go — a tab reads
      // "npm · myrepo" while npm runs and "myrepo" when it finishes.
      // That is deliberate, and it is also why tab titles look restless
      // if you are watching them.
      if (interesting) return { text: interesting, fromCwd: false };
      if (prog) return { text: tail && !home ? `${prog} · ${tail}` : prog, fromCwd: false };
      return dirLabel();
    }
  }
}

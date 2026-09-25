# TV Renamer

A PowerShell script that renames downloaded TV episodes using episode titles from [TMDb](https://www.themoviedb.org/) and moves them into a tidy library folder.

```
Ted.Lasso.S04E07.Yes.and.Baby.1080p.WEB-DL.mkv
  -> TV Series\Ted Lasso\Season 04\Ted Lasso - S04E07 - Yes & Baby.mkv
```

## Setup

1. Get a free TMDb API key from your TMDb account under Settings > API. Use the **API Key**, not the API Read Access Token.
2. Store the key as a user environment variable (one time only), then open a new PowerShell window:
   ```powershell
   [Environment]::SetEnvironmentVariable("TMDB_API_KEY", "<your key>", "User")
   ```
3. Clone the repo (or just download `TVRenamer.ps1`):
   ```
   cd C:\git
   git clone https://github.com/Valiante/tv-renamer
   ```

The key is never stored in the script, so it stays out of the repo.

## Usage

Run from PowerShell (not Command Prompt):

```powershell
cd C:\git\tv-renamer
.\TVRenamer.ps1 "D:\Downloads\TV" "D:\Media\TV Series" -DryRun   # preview only, nothing is moved
.\TVRenamer.ps1 "D:\Downloads\TV" "D:\Media\TV Series"           # asks for Y before moving anything
```

| Parameter | Purpose |
| --- | --- |
| `-Source` (1st) | Folder of new downloads to process (searched recursively) |
| `-Destination` (2nd) | Library root; files are moved to `<Show>\Season NN\` under here |
| `-DryRun` | Preview the renames without moving anything |

`-Source` and `-Destination` are required; if you leave them out, PowerShell prompts for them. Both folders must already exist. Network paths such as `\\nas\video\TV Series` work too.

Only files over 100MB are processed, so samples and subtitles are ignored.

Desktop shortcut:

- **Target:** `powershell.exe -ExecutionPolicy Bypass -File "C:\git\tv-renamer\TVRenamer.ps1" "D:\Downloads\TV" "D:\Media\TV Series"`
- **Start in:** `C:\git\tv-renamer`

## How it works

1. Finds the `S00E00` marker in each filename. Everything before it is the show name, everything after it (up to quality tags like `1080p`) is the episode title.
2. Searches TMDb for the show, using any year in the name (e.g. `(2016)`) as a hint. Titles containing dots such as `11.22.63` or `S.W.A.T.` are handled.
3. Looks up the episode title. If the filename's title doesn't match TMDb's episode at that number, it searches the whole season for a matching title and uses that episode number instead.
4. Title matching ignores case, punctuation and apostrophes, and treats `&` as `and`, so `Dont` matches `Don't` and `Yes and Baby` matches `Yes & Baby`.
5. Shows the plan, then moves the files after you confirm.

Files are skipped, with the reason shown in the summary, when:

- there is no `S00E00` marker
- the show or episode can't be found on TMDb
- the filename's episode title doesn't match anything in that season
- the target file already exists, or two files would get the same name

## Updating

After changes are pushed to GitHub:

```powershell
cd C:\git\tv-renamer
git pull
```

## Troubleshooting

| Message | Fix |
| --- | --- |
| `TMDB_API_KEY environment variable is not set` | Set it (see Setup), then open a **new** PowerShell window |
| `TMDb rejected the API key (401)` | The key is wrong or was regenerated; update the environment variable |
| `running scripts is disabled on this system` | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once |
| Script opens in an editor instead of running | You're in Command Prompt; type `powershell` first |
| `Folder not found` | Check the `-Source` / `-Destination` paths, and quote any path containing spaces |
| A file is skipped for a title mismatch | Check the skip reason in the summary; it shows both titles |

## License

[MIT](LICENSE)

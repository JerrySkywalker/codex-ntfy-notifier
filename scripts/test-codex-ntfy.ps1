$payload = '{"hook_event_name":"Stop","cwd":"C:\\Dev","model":"manual-test","last_assistant_message":"Windows → ntfy → Android test succeeded."}'
$payload | cmd.exe /c "%USERPROFILE%\.codex\notify-ntfy.cmd"
Get-Content "$env:USERPROFILE\.codex\notify-ntfy.log" -Tail 40

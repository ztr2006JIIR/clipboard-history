Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

appRoot = fso.GetParentFolderName(WScript.ScriptFullName)
dataDir = fso.BuildPath(appRoot, "data")
scriptPath = fso.BuildPath(appRoot, "clipboard-history.ps1")
logPath = fso.BuildPath(dataDir, "launch.log")

If Not fso.FolderExists(dataDir) Then
    fso.CreateFolder(dataDir)
End If

Set logFile = fso.OpenTextFile(logPath, 2, True)
logFile.WriteLine Now & " launch start"
logFile.Close

command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File " & Chr(34) & scriptPath & Chr(34)
shell.Run command, 0, False

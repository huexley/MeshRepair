property engine : "__ENGINE__"

on run
	set picked to choose file with prompt "Choose 3D files to repair (STL, 3MF, OBJ, PLY):" of type {"stl", "3mf", "obj", "ply", "off", "glb", "public.standard-tesselated-geometry-format"} with multiple selections allowed
	repairFiles(picked)
end run

on open dropped
	repairFiles(dropped)
end open

on repairFiles(fileList)
	set args to ""
	repeat with f in fileList
		set args to args & " " & quoted form of POSIX path of f
	end repeat
	display notification "Repairing " & (count of fileList) & " file(s)…" with title "Mesh Repair"
	try
		set report to do shell script engine & args & " 2>&1"
	on error errMsg
		set report to errMsg
	end try
	display dialog report buttons {"Show in Finder", "OK"} default button "OK" with title "Mesh Repair" with icon note
	if button returned of result is "Show in Finder" then
		tell application "Finder"
			reveal (item 1 of fileList)
			activate
		end tell
	end if
end repairFiles

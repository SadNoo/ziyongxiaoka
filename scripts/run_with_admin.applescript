on run argv
    if (count of argv) is less than 2 then error "missing privileged helper arguments"
    set helperPath to item 1 of argv
    set commandText to quoted form of helperPath
    repeat with argumentValue in items 2 thru -1 of argv
        set commandText to commandText & " " & quoted form of (argumentValue as text)
    end repeat
    do shell script commandText with administrator privileges
end run

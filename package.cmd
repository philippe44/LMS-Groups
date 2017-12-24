@echo off
SET version=0.1.13
rem SET type=stable
SET devroot=..\LMS-Groups
xcopy "%devroot%\CHANGELOG" "%devroot%\plugin" /y /d
CALL :zipxml %type%
goto :eof

:zipxml 
"c:\perl\bin\perl" ..\LMS\package.pl version "%devroot%" Groups %version% %1
del "%devroot%\Groups*.zip"
"C:\Program Files\7-Zip\7z.exe" a -r "%devroot%\Groups-%version%.zip" "%devroot%\plugin\*"
"c:\perl\bin\perl" ..\LMS\package.pl sha "%devroot%" Groups %version% %1
if %1 == stable xcopy "%devroot%\Groups-%version%.zip" "%devroot%\..\LMS\" /y /d
goto :eof



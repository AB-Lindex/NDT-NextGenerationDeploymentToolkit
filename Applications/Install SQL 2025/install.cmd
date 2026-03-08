@REM this bat file will be retired and true pwsh will be used only once migrated fully to NDT.
@REM install.cmd "SQL41,SQL42,SQL43" "gMSAAO04" "10.0.3.64" "sql-cluster04" "\\dc01.corp.dev\SQL-Witness" "10.0.3.65" "sql-listen04" "SQL-AG" "sql-listen04.corp.dev.pfx" "SAPWD"

powershell.exe -executionpolicy bypass -file .\install.ps1 %*
  
@REM powershell.exe -executionpolicy bypass -file .\install.ps1 ^
@REM   -SQLAONodes %1 ^
@REM   -SQLAOgMSA %2 ^
@REM   -SQLAOClusterIP %3 ^
@REM   -SQLAOClusterName %4 ^
@REM   -SQLAOClusterShare %5 ^
@REM   -SQLAOListenerIP %6 ^
@REM   -SQLAOListenerName %7 ^
@REM   -AGName %8 ^
@REM   -SQLPFXFile %9 ^
@REM   -SAPWD %10

@REM pause

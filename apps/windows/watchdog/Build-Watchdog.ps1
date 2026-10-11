# //! 只编译守护程序，不注册或操作输入法。
param([Parameter(Mandatory=$true)][string]$Compiler,[Parameter(Mandatory=$true)][string]$OutputDir,[switch]$WithTests)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
& $Compiler '-std=c++20' '-O2' '-Wall' '-Wextra' '-Werror' '-municode' '-mwindows' '-static' '-fno-exceptions' '-fno-rtti' (Join-Path $PSScriptRoot 'Watchdog.cpp') '-o' (Join-Path $OutputDir 'qingjian-watchdog.exe') '-ladvapi32' '-lshell32' '-luser32'
if($LASTEXITCODE -ne 0){throw '守护程序编译失败'}
if($WithTests){
 & $Compiler '-std=c++20' '-O2' '-Wall' '-Wextra' '-Werror' '-municode' '-mwindows' '-static' '-fno-exceptions' '-fno-rtti' '-DWATCHDOG_TEST' (Join-Path $PSScriptRoot 'Watchdog.cpp') '-o' (Join-Path $OutputDir 'watchdog-test.exe') '-ladvapi32' '-lshell32' '-luser32'
 if($LASTEXITCODE -ne 0){throw '守护测试程序编译失败'}
 & $Compiler '-std=c++20' '-O2' '-Wall' '-Wextra' '-Werror' '-municode' '-mwindows' '-static' (Join-Path $PSScriptRoot 'tests\Fixture.cpp') '-o' (Join-Path $OutputDir 'fixture.exe')
 if($LASTEXITCODE -ne 0){throw '隔离测试进程编译失败'}
}

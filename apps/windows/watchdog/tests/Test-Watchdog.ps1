# //! 守护集成测试只操作本目录内的合成进程，不连接用户输入服务。
param([Parameter(Mandatory=$true)][string]$BinDir,[Parameter(Mandatory=$true)][string]$WorkDir)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $WorkDir -Force|Out-Null
$BinDir=[IO.Path]::GetFullPath($BinDir)
$WorkDir=[IO.Path]::GetFullPath($WorkDir)
$checks=[Collections.Generic.List[object]]::new()
$guard=$null;$caseDir=$null
function Wait-Until([scriptblock]$Check,[string]$Message,[int]$Timeout=12000){
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while($watch.ElapsedMilliseconds -lt $Timeout){
  if(& $Check){return}; Start-Sleep -Milliseconds 150
 }
 throw $Message
}
function Owned([string]$Name,[string]$Directory){
 @(Get-Process -Name $Name -ErrorAction SilentlyContinue|Where-Object {$_.Path -and [string]::Equals($_.Path,(Join-Path $Directory ($Name+'.exe')),[StringComparison]::OrdinalIgnoreCase)})
}
function Clean-Case {
 if($script:caseDir){
  $prefix=[IO.Path]::GetFullPath($script:caseDir)+'\'
  foreach($name in @('watchdog-test','test-server')){
   Get-Process -Name $name -ErrorAction SilentlyContinue|Where-Object {$_.Path -and $_.Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)}|Stop-Process -Force -ErrorAction SilentlyContinue
  }
 }
 if($script:guard){$script:guard.Dispose();$script:guard=$null}
}
function Start-Case([string]$Name){
 Clean-Case
 $script:caseDir=Join-Path $WorkDir ($Name+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
 New-Item -ItemType Directory -Path $script:caseDir -Force|Out-Null
 foreach($name in @('watchdog-test.exe','test-server.exe')){
  $source=if($name -eq 'watchdog-test.exe'){$name}else{'fixture.exe'}
  Copy-Item -LiteralPath (Join-Path $BinDir $source) -Destination (Join-Path $script:caseDir $name)
 }
 [IO.File]::WriteAllText((Join-Path $script:caseDir 'test-active.flag'),'active')
}
function Launch-Guard {
 $script:guard=Start-Process -FilePath (Join-Path $script:caseDir 'watchdog-test.exe') -WorkingDirectory $script:caseDir -WindowStyle Hidden -PassThru
 Wait-Until { (Owned 'test-server' $script:caseDir).Count -eq 1 } '合成进程启动失败'
}
function Exit-Component([string]$Name,[int]$Code){
 [IO.File]::WriteAllText((Join-Path $script:caseDir ($Name+'.exe.exit')),[string]$Code)
}
try{
 Start-Case 'recovery';Launch-Guard
 $server=(Owned 'test-server' $caseDir)[0].Id
 Exit-Component 'test-server' 7
 Wait-Until {$p=Owned 'test-server' $caseDir;$p.Count -eq 1 -and $p[0].Id -ne $server} '服务异常退出未恢复'
 $checks.Add(@{test='服务异常退出自动恢复';passed=$true})
 $duplicate=Start-Process -FilePath (Join-Path $caseDir 'watchdog-test.exe') -WindowStyle Hidden -PassThru
 if(-not $duplicate.WaitForExit(4000) -or $duplicate.ExitCode -ne 0){throw '单实例保护失败'}
 $duplicate.Dispose();if($guard.HasExited){throw '重复启动影响了原守护'}
 $checks.Add(@{test='守护单实例保护';passed=$true})
 $server=(Owned 'test-server' $caseDir)[0].Id
 Exit-Component 'test-server' 0
 Wait-Until {$s=Owned 'test-server' $caseDir;$s.Count -eq 1 -and $s[0].Id -ne $server} '普通零退出未恢复'
 if($guard.HasExited){throw '普通零退出误停止守护'}
 $checks.Add(@{test='普通零退出仍恢复，避免重复进程退出误停守护';passed=$true})
 Start-Case 'explicit-stop';Launch-Guard
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $scope=$identity.User.Value+'-'+[Diagnostics.Process]::GetCurrentProcess().SessionId+'-test-'+(Split-Path $caseDir -Leaf)
 $identity.Dispose()
 $stop=[Threading.EventWaitHandle]::OpenExisting('Local\QingjianServerWatchdogStop-'+$scope)
 $stop.Set()|Out-Null
 if(-not $guard.WaitForExit(4000)){throw '主动停止信号未生效'}
 $stop.Dispose()
 if((Owned 'test-server' $caseDir).Count -ne 1){throw '停止守护误结束输入程序'}
 $checks.Add(@{test='主动停止信号有效且不结束现有程序';passed=$true})

 Start-Case 'pause-marker';Launch-Guard
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 [IO.File]::WriteAllText((Join-Path $caseDir 'watchdog-paused.flag'),($identity.User.Value+[Environment]::NewLine+$caseDir+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
 $identity.Dispose()
 if(-not $guard.WaitForExit(4000)){throw '主动暂停标记未停止守护'}
 if((Owned 'test-server' $caseDir).Count -ne 1){throw '暂停标记误结束现有程序'}
 $checks.Add(@{test='用户与目录匹配的暂停标记停止守护且保留现有输入';passed=$true})

 Start-Case 'maintenance';Launch-Guard
 $installer=[Threading.Mutex]::new($false,'Local\QingjianWatchdogTestInstaller')
 try{if(-not $guard.WaitForExit(4000)){throw '安装维护期间守护未停止'}}finally{$installer.Dispose()}
 $checks.Add(@{test='安装维护时停止恢复';passed=$true})

 Start-Case 'registration';Launch-Guard
 Remove-Item -LiteralPath (Join-Path $caseDir 'test-active.flag')
 if(-not $guard.WaitForExit(4000)){throw '注册变化后守护未停止'}
 $checks.Add(@{test='注册变化停止守护';passed=$true})

 Start-Case 'backoff'
 [IO.File]::WriteAllText((Join-Path $caseDir 'test-server.exe.startup-exit'),'6')
 $guard=Start-Process -FilePath (Join-Path $caseDir 'watchdog-test.exe') -WorkingDirectory $caseDir -WindowStyle Hidden -PassThru
 Wait-Until {(Test-Path -LiteralPath (Join-Path $caseDir 'watchdog.log')) -and [IO.File]::ReadAllText((Join-Path $caseDir 'watchdog.log')).Contains('retry_ms=4000')} '连续失败没有逐步退避' 15000
 $text=[IO.File]::ReadAllText((Join-Path $caseDir 'watchdog.log'))
 if(-not $text.Contains('retry_ms=1000') -or -not $text.Contains('retry_ms=2000')){throw '失败退避间隔无效'}
 $checks.Add(@{test='连续崩溃按1、2、4秒退避';passed=$true})

 Start-Case 'path-conflict'
 $alternate=Join-Path $caseDir 'alternate'
 New-Item -ItemType Directory -Path $alternate -Force|Out-Null
 Copy-Item -LiteralPath (Join-Path $BinDir 'fixture.exe') -Destination (Join-Path $alternate 'test-server.exe')
 $other=Start-Process -FilePath (Join-Path $alternate 'test-server.exe') -WorkingDirectory $alternate -WindowStyle Hidden -PassThru
 Wait-Until {(Owned 'test-server' $alternate).Count -eq 1} '外部路径测试进程未启动'
 $guard=Start-Process -FilePath (Join-Path $caseDir 'watchdog-test.exe') -WorkingDirectory $caseDir -WindowStyle Hidden -PassThru
 Wait-Until {(Test-Path -LiteralPath (Join-Path $caseDir 'watchdog.log')) -and [IO.File]::ReadAllText((Join-Path $caseDir 'watchdog.log')).Contains('身份或路径冲突')} '其他路径的同名程序未被拒绝'
 if((Owned 'test-server' $caseDir).Count -ne 0 -or $other.HasExited){throw '路径冲突处理错误'}
 $other.Dispose()
 $checks.Add(@{test='拒绝恢复其他目录的同名程序且不结束它';passed=$true})
 [IO.File]::WriteAllText((Join-Path $WorkDir 'integration-results.json'),(@{Passed=$true;checks=@($checks)}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 $checks | ConvertTo-Json -Depth 4
} catch {
 [IO.File]::WriteAllText((Join-Path $WorkDir 'integration-results.json'),(@{Passed=$false;checks=@($checks);Error=$_.Exception.Message}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 throw
} finally{Clean-Case}

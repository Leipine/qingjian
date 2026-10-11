# //! 只创建带随机测试前缀的当前用户任务，守护和假服务均位于显式测试目录。
param([Parameter(Mandatory=$true)][string]$BinDir,[Parameter(Mandatory=$true)][string]$WorkDir)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetFullPath($WorkDir)) ('task-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$prefix='QingjianWatchdog-Test-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$name=$prefix+'-'+$sid
$script=Join-Path $PSScriptRoot '..\watchdog-task.ps1'
Copy-Item -LiteralPath (Join-Path $BinDir 'watchdog-test.exe') -Destination (Join-Path $root 'qingjian-watchdog.exe')
Copy-Item -LiteralPath (Join-Path $BinDir 'fixture.exe') -Destination (Join-Path $root 'test-server.exe')
[IO.File]::WriteAllText((Join-Path $root 'test-active.flag'),'active')
function Change([string]$Action){& $script -Action $Action -InstallDirectory $root -TestTaskPrefix $prefix}
function Owned([string]$Name){@(Get-Process -Name $Name -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq (Join-Path $root ($Name+'.exe'))})}
function Wait-Until([scriptblock]$Check,[int]$Timeout=12000){
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while($watch.ElapsedMilliseconds -lt $Timeout){if(& $Check){return $watch.ElapsedMilliseconds};Start-Sleep -Milliseconds 150}
 throw '隔离任务验证超时'
}
$svc=New-Object -ComObject Schedule.Service
$svc.Connect()
$folder=$svc.GetFolder('\')
try{
 Change 'Resume'
 [void](Wait-Until {(Owned 'qingjian-watchdog').Count -eq 1 -and (Owned 'test-server').Count -eq 1})
 $task=$folder.GetTask($name)
 $definition=$task.Definition
 $xml=[xml]$definition.XmlText
 if($xml.Task.Principals.Principal.UserId -ne $sid -or $definition.Principal.RunLevel -ne 0 -or $definition.Settings.ExecutionTimeLimit -ne 'PT0S'){throw '任务身份或运行设置不正确'}
 $poll=@($definition.Triggers|Where-Object {$_.Id -eq 'WatchdogSafetyPoll'})
 if($poll.Count -ne 1 -or $poll[0].Repetition.Interval -ne 'PT1M'){throw '每分钟定时恢复未配置'}
 $server=(Owned 'test-server')[0].Id
 Change 'Pause'
 [void](Wait-Until {(Owned 'qingjian-watchdog').Count -eq 0})
 if($folder.GetTask($name).Enabled -or (Owned 'test-server')[0].Id -ne $server){throw '暂停影响现有输入或未停用任务'}
 Change 'Resume'
 [void](Wait-Until {(Owned 'qingjian-watchdog').Count -eq 1})
 Change 'Resume'
 [void](Wait-Until {(Owned 'qingjian-watchdog').Count -eq 1})
 $before=(Owned 'qingjian-watchdog')[0].Id
 Stop-Process -Id $before -Force
 $elapsed=Wait-Until {$guard=Owned 'qingjian-watchdog';$guard.Count -eq 1 -and $guard[0].Id -ne $before} 85000
 Change 'MaintenanceStop'
 Change 'MaintenanceStop'
 if($folder.GetTask($name).Enabled){throw '维护期间任务未禁用'}
 Change 'MaintenanceResume'
 if(-not $folder.GetTask($name).Enabled){throw '维护后未恢复原启用状态'}
 Change 'Pause'
 Change 'MaintenanceStop'
 Change 'MaintenanceResume'
 if($folder.GetTask($name).Enabled){throw '维护覆盖了用户暂停状态'}
 # 同名外部任务不得覆盖：只改自己的隔离任务标记后检查拒绝。
 $task=$folder.GetTask($name)
 $definition=$task.Definition
 $definition.RegistrationInfo.Source='ForeignFixture'
 [void]$folder.RegisterTaskDefinition($name,$definition,6,$sid,$null,3,$null)
 $rejected=$false
 try{Change 'Resume'}catch{$rejected=$true}
 if(-not $rejected -or $folder.GetTask($name).Definition.RegistrationInfo.Source -ne 'ForeignFixture'){throw '未保护外部同名任务'}
 $definition.RegistrationInfo.Source='Qingjian.Watchdog.1'
 [void]$folder.RegisterTaskDefinition($name,$definition,6,$sid,$null,3,$null)
 [IO.File]::WriteAllText((Join-Path $WorkDir 'task-results.json'),(@{Passed=$true;TaskRecoveryMs=$elapsed;CurrentUserOnly=$true;PausePreservesServer=$true;MaintenancePreservesPause=$true;ForeignTaskProtected=$true}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 Get-Content -LiteralPath (Join-Path $WorkDir 'task-results.json') -Raw
}finally{
 Change 'Remove'
 foreach($kind in @('qingjian-watchdog','test-server')){Owned $kind|Stop-Process -Force -ErrorAction SilentlyContinue}
}

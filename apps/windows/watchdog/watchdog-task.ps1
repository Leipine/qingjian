# //! 当前用户的可选守护任务；所有更新、暂停与删除均校验 SID、标记和完整动作路径。
param(
 [ValidateSet('Resume','Pause','Remove','MaintenanceStop','MaintenanceResume')][string]$Action='Resume',
 [string]$InstallDirectory=$PSScriptRoot,
 [string]$TestTaskPrefix=''
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$sid=$identity.User.Value
$identity.Dispose()
$source='Qingjian.Watchdog.1'
$prefix='QingjianWatchdog-'
$pause=Join-Path $env:LOCALAPPDATA 'Qingjian\watchdog-paused.flag'
$scope=$sid+'-'+[Diagnostics.Process]::GetCurrentProcess().SessionId
if($TestTaskPrefix){
 if(-not $TestTaskPrefix.StartsWith('QingjianWatchdog-Test-') -or -not (Test-Path -LiteralPath (Join-Path $root 'test-active.flag'))){throw '隔离测试作用域无效'}
 $prefix=$TestTaskPrefix+'-'
 $pause=Join-Path $root 'watchdog-paused.flag'
 $scope+='-test-'+(Split-Path -Path $root -Leaf)
}
$name=$prefix+$sid
$exe=Join-Path $root 'qingjian-watchdog.exe'
$maintenance=Join-Path $root 'watchdog-maintenance.json'
function Same-Path([string]$a,[string]$b){
 if(-not $a -or -not $b){return $false}
 return [string]::Equals([IO.Path]::GetFullPath($a).TrimEnd('\'),[IO.Path]::GetFullPath($b).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
}
function Is-Owned($task,[string]$expectedSid){
 try{
  $d=$task.Definition
  $xml=[xml]$d.XmlText
  if($d.Actions.Count -ne 1){return $false}
  $a=$d.Actions.Item(1)
  return $xml.Task.Principals.Principal.UserId -eq $expectedSid -and
   $d.Principal.LogonType -eq 3 -and $d.Principal.RunLevel -eq 0 -and
   $d.RegistrationInfo.Source -eq $source -and
   $d.RegistrationInfo.Description -eq ($source+'|'+$expectedSid+'|'+$root.ToUpperInvariant()) -and
   $a.Type -eq 0 -and -not $a.Arguments -and (Same-Path $a.Path $exe) -and (Same-Path $a.WorkingDirectory $root)
 }catch{return $false}
}
function Find-Task([string]$taskName){
 try{return $folder.GetTask($taskName)}catch{if($_.Exception.HResult -eq -2147024894){return $null};throw}
}
$service=New-Object -ComObject Schedule.Service
$service.Connect()
$folder=$service.GetFolder('\')
if($Action -in @('MaintenanceStop','MaintenanceResume','Remove')){
 if($Action -eq 'MaintenanceResume'){
  if(-not (Test-Path -LiteralPath $maintenance)){return}
  if((Get-Item -LiteralPath $maintenance).Length -gt 65536){throw '维护记录过大'}
  $records=@(Get-Content -LiteralPath $maintenance -Raw -Encoding UTF8|ConvertFrom-Json)
  foreach($record in $records){
   if($TestTaskPrefix){if($record.Name -ne $name -or $record.Sid -ne $sid){continue}}
   elseif($record.Name -notmatch '^QingjianWatchdog-(S-1-\d+(?:-\d+)+)$' -or $Matches[1] -ne $record.Sid){continue}
   $t=Find-Task $record.Name
   if($t -and (Is-Owned $t $record.Sid)){$t.Enabled=[bool]$record.Enabled}
  }
  Remove-Item -LiteralPath $maintenance
  return
 }
 $tasks=@()
 foreach($t in $folder.GetTasks(1)){
  if($TestTaskPrefix){$matchesName=$t.Name -eq $name;$taskSid=$sid}
  else{$matchesName=$t.Name -match '^QingjianWatchdog-(S-1-\d+(?:-\d+)+)$';if(-not $matchesName){continue};$taskSid=$Matches[1]}
  if(-not $matchesName -or -not (Is-Owned $t $taskSid)){continue}
  $tasks+=@{Task=$t;Sid=$taskSid}
 }
 if($Action -eq 'MaintenanceStop' -and -not (Test-Path -LiteralPath $maintenance)){
  # 先持久化再停任务；重复维护保留首次状态，失败或取消可恢复。
  $records=@($tasks|ForEach-Object {@{Name=[string]$_.Task.Name;Sid=$_.Sid;Enabled=[bool]$_.Task.Enabled}})
  $temporary=$maintenance+'.tmp'
  [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject @($records)),[Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temporary -Destination $maintenance -Force
 }
 foreach($item in $tasks){
  $t=$item.Task
  $t.Enabled=$false
  $t.Stop(0)
  if($Action -eq 'Remove'){$folder.DeleteTask($t.Name,0)}
 }
 return
}
$t=Find-Task $name
if($t -and -not (Is-Owned $t $sid)){throw '同名计划任务不属于本安装，未修改'}
if($Action -eq 'Pause'){
 New-Item -ItemType Directory -Path (Split-Path -Parent $pause) -Force|Out-Null
 [IO.File]::WriteAllText($pause,($sid+"`n"+$root+"`n"),[Text.UTF8Encoding]::new($false))
 if($t){$t.Enabled=$false}
 try{$stop=[Threading.EventWaitHandle]::OpenExisting('Local\QingjianServerWatchdogStop-'+$scope);try{[void]$stop.Set()}finally{$stop.Dispose()}}catch [Threading.WaitHandleCannotBeOpenedException]{}
 return
}
if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){throw '守护程序文件缺失'}
if(Test-Path -LiteralPath $pause){
 if((Get-Item -LiteralPath $pause).Length -gt 4096){throw '暂停记录无效'}
 $lines=@(Get-Content -LiteralPath $pause -Encoding UTF8)
 if($lines.Count -ne 2 -or $lines[0] -ne $sid -or -not (Same-Path $lines[1] $root)){throw '暂停记录不属于此安装，未覆盖'}
 Remove-Item -LiteralPath $pause
}
# 显式恢复时更新本任务定义，修复旧设置；保持当前用户、普通权限和单实例。
$d=$service.NewTask(0)
$d.RegistrationInfo.Source=$source
$d.RegistrationInfo.Description=$source+'|'+$sid+'|'+$root.ToUpperInvariant()
$d.Principal.UserId=$sid
$d.Principal.LogonType=3
$d.Principal.RunLevel=0
$d.Settings.Enabled=$true
$d.Settings.DisallowStartIfOnBatteries=$false
$d.Settings.StopIfGoingOnBatteries=$false
$d.Settings.ExecutionTimeLimit='PT0S'
$d.Settings.MultipleInstances=2
$d.Settings.StartWhenAvailable=$true
$d.Settings.RestartInterval='PT1M'
$d.Settings.RestartCount=10
$logon=$d.Triggers.Create(9)
$logon.UserId=$sid
$logon.Delay='PT5S'
$periodic=$d.Triggers.Create(1)
$periodic.Id='WatchdogSafetyPoll'
$periodic.StartBoundary=[DateTime]::Now.AddMinutes(1).ToString("yyyy-MM-dd'T'HH:mm:ss",[Globalization.CultureInfo]::InvariantCulture)
$periodic.Repetition.Interval='PT1M'
$periodic.Repetition.StopAtDurationEnd=$false
$a=$d.Actions.Create(0)
$a.Path=$exe
$a.Arguments=''
$a.WorkingDirectory=$root
$t=$folder.RegisterTaskDefinition($name,$d,6,$sid,$null,3,$null)
$t.Enabled=$true
[void]$t.Run($null)

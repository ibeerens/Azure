# AD Connect Sync
Import-Module -Name "C:\Program Files\Microsoft Azure AD Sync\Bin\ADSync"
Start-ADSyncSyncCycle -PolicyType Delta

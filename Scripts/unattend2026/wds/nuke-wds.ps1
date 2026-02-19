stop-service WDSServer
remove-item c:\remoteInstall\ -Recurse -Force
wdsutil /unInitialize-server
wdsUTIL /initialize-Server /Reminst:"C:\RemoteInstall"
wdsutil /Add-Image /ImageFile:"C:\Deploy2026\Boot\boot2026.wim" /ImageType:Boot /Name:"PE Boot 2026"
start-service WDSServer


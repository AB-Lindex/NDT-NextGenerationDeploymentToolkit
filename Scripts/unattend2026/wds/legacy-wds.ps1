stop-service WDSServer

wdsutil /Remove-Image /Image:"PE Boot 2026" /ImageType:Boot /Architecture:x64 /Filename:"boot2026.wim"
wdsutil /Verbose /Add-Image /ImageFile:"C:\Deploy2026\Boot\boot2026.wim" /ImageType:Boot /Name:"PE Boot 2026"

start-service WDSServer

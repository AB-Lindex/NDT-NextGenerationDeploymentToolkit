@echo off
rem startnet.cmd - called if winpeshl.ini is absent (fallback only)
rem wpeinit initializes network stack AND starts DHCP - do not call net start dhcp before it
wpeinit

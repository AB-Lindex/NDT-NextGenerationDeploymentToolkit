# NDT-NextGenerationDeploymentToolkit
A light Powershell based version of MDT, now that MDT is EOL. 
My goal is to keep it simple with mostly powershell 5 and 7 with WDS and PXE as boot solution and simple application management with JSON as parameter files. 
No GUI :)

As of now:
No version numbers yet. The solution is PGD - Pretty Good Deployment :)
in the pipe: 
* reference image creation, more than halfway there
* Build script to setup the NDT server
* considerations for some JSON-files. keep as is or separate, they are growing

What is already working:
* Good OS deployment based on MAC address as input for unattended deployment
* Support for reboot during installation and pick up where we left!
* Support for changing account used during AutoAdminLogon. My best examples are unattended creation of gMSA 
  which is best done while logged on as an AD account as well as well as cluster creation and similar (SQL Always On kit)
* Doing installations of whatever software you like using scripting that can be ps5, ps7 or cmd where the proper environment will be selected

 
  

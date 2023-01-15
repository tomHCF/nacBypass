# nacBypass
The main use of this tool is 802.1X Network Access Control bypass. It is also useful in MITM attacks.

nacBypass.sh was tested on the Raspberry Pi running Kali Linux with 2 USB network adapters attached (RTL8153 chip)

This tool is the result of testing and experimentation with networks, NAC and nac_bypass_setup.sh (by Michael Schneider - https://github.com/scipag/nac_bypass)

## Usage:
```
$ ./nacBypass.sh -h
   -1 <eth>    Network interface connected to the switch
   -2 <eth>    Network interface connected to the victim machine
   -R          Add routes to gateway and victim machine
   -h          Help
   -r          Reset
```

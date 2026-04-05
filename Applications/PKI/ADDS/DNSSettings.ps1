Add-DnsServerConditionalForwarderZone -Name "corp.dev" -ReplicationScope "Forest" -MasterServers 10.0.3.11
Set-DnsServerForwarder -IPAddress 8.8.8.8

Add-DnsServerPrimaryZone -name "pkilab.corp" -ReplicationScope "Forest"

Add-DnsServerResourceRecordA -Name "crl" -ZoneName "pkilab.corp" -IPv4Address "10.0.1.102"
# Add-DnsServerResourceRecordA -Name "ocsp" -ZoneName "pkilab.corp" -IPv4Address "10.0.1.102" # OCSP is not used in this lab, but the record is created for demonstration purposes.


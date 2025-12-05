// Define Providers
var REG_NONE = NewRegistrar("none");
var CF = NewDnsProvider("cloudflare");

var PROVIDERS = {
  "cloudflare": CF,
  "none": REG_NONE
};

// Load and Parse YAML Data from Environment Variable
var rawData = process.env.DNS_ZONES_JSON;
if (!rawData) {
  throw new Error("❌ Error: DNS_ZONES_JSON environment variable is missing.");
}

var config = JSON.parse(rawData);


/*
    Define Cloudflare Proxy Modifiers

    This script allows us to manage the DNS records dynamically based on dns_zones.enc.yaml configuration. This file shouldn't need to be edited directly; instead, modify the YAML file and let the deployment script handle the rest.

*/
for (var domainName in config.domains) {
  var domainData = config.domains[domainName];
  var records = [];

  // Process Records
  if (domainData.records) {
    for (var i = 0; i < domainData.records.length; i++) {
      var r = domainData.records[i];
      var modifiers = [];
      
      // Handle Cloudflare Proxy Toggle
      if (r.proxied === true) {
        modifiers.push(CF_PROXY_ON);
      } else if (r.proxied === false) {
        modifiers.push(CF_PROXY_OFF);
      }

      // Add Record
      // This dynamically calls A(), CNAME(), TXT(), etc.
      records.push(DnsRecord(r.type, r.name, r.target, modifiers));
    }
  }

  // Register the Domain
  D(domainName, 
    REG_NONE, 
    DnsProvider(PROVIDERS[domainData.provider]), 
    records
  );
}
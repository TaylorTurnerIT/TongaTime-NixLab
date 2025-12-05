var run = require('child_process').execSync;

// Define Providers
var REG_NONE = NewRegistrar("none");
var CF = NewDnsProvider("cloudflare");

var PROVIDERS = {
  "cloudflare": CF,
  "none": REG_NONE
};

// Decrypt & Parse Zone Config (In-Memory)
// We execute sops inside the container to read the encrypted YAML file
// and convert it to JSON for parsing.
try {
  // Note: This assumes the container mounts the file at /work/network/dns_zones.yaml
  var rawZones = run("sops -d network/dns_zones.yaml | yq -o=json").toString();
} catch (e) {
  throw new Error("❌ Failed to decrypt zones. Ensure sops/age keys are mounted.\n" + e.message);
}

var config = JSON.parse(rawZones);

// Generate Domains
for (var domainName in config.domains) {
  var domainData = config.domains[domainName];
  var records = [];

  if (domainData.records) {
    for (var i = 0; i < domainData.records.length; i++) {
      var r = domainData.records[i];
      var modifiers = [];
      
      // Handle Cloudflare Proxy
      if (r.proxied === true) modifiers.push(CF_PROXY_ON);
      if (r.proxied === false) modifiers.push(CF_PROXY_OFF);

      records.push(DnsRecord(r.type, r.name, r.target, modifiers));
    }
  }

  D(domainName, 
    REG_NONE, 
    DnsProvider(PROVIDERS[domainData.provider]), 
    records
  );
}
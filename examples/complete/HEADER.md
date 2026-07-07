<!--
  Header for the complete example README. Edit this file, then run `just docs`
  (or ./Sort-LdoTerraform.ps1 -IncludeExamples) to regenerate the section between the markers.
  The example's main.tf is embedded into the README automatically (see .terraform-docs.yml).
-->
<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="200">
    </picture>
  </a>
</div>

# Complete example

Exercises the fuller surface of this module, built around the secret-rotation exemplar: a Key
Vault system topic delivers near-expiry events over an Event Grid webhook into a Consumption
Logic App workflow that regenerates the inactive storage key and writes the rotated secret back
as a new version (see `templates/rotation-handler.json.tftpl`). Around it sit a
public-network-disabled custom topic, a domain with its domain topics, managed-identity queue
delivery with blob dead-lettering and in-module delivery role assignments, and the TLS 1.2 shim
on topics and domains. The rotor vault is deliberately network-open and RBAC-gated (see the
security scan exceptions table in the repo README); the private example shows the
deny-by-default posture. The environment comes from the Terraform workspace
(`terraform.workspace`), not a variable. Run it with `just e2e complete`, which applies the
stack then always destroys it.

[![Terraform Registry](https://img.shields.io/badge/registry-libre--devops-7B42BC?logo=terraform&logoColor=white)](https://registry.terraform.io/namespaces/libre-devops)

## Running the rotation live

With the stack deployed, `./Seed-RotationTest.ps1` stores the storage account's current active
key as a secret version expiring inside Key Vault's fixed 30 day near-expiry window, tagged with
the rotation contract (`Kind`, `CredentialId`, `ProviderAddress`). Key Vault raises
`SecretNearExpiry` within minutes, Event Grid delivers it to the rotor workflow, and the rotor:

1. regenerates the INACTIVE key (`key1`/`key2` alternation, so the active key never breaks),
2. writes it back as a new secret version with the expiry restarted to `rotation_validity_days`,
   `CredentialId` flipped to the now-active key, and `RotatedBy`/`RotatedAt` stamped,
3. disables the rotated-out version, so anything pinned to it gets a hard 403 instead of a key
   that quietly dies at expiry.

Verify with `az keyvault secret show` (new version, flipped tags), the key hashes on the storage
account (the inactive one changed, the active one untouched), and the workflow run history. The
script is re-runnable: each pass carries the current `CredentialId` forward and rotates the
other key. The caller needs vault secrets data-plane rights and storage key list rights; the
vault is network-open by design here (public tier), so no firewall dance is needed.

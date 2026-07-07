<!--
  Header for the private example README. Edit this file, then run `just docs`
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

# Private example

The private tier of the rotation chassis: the custom topic, the vault, and both storage
subresources sit behind private endpoints, with their privatelink zones (eventgrid, vaultcore,
queue, blob) linked to the vnet through the Libre DevOps private-dns-zone and private-endpoint
modules. Event Grid delivers near-expiry events by managed identity onto a queue in a storage
account that denies public network access: a resource instance rule scoped to the system topic
does the admitting, so there is no public opening and no service-wide trusted bypass. The
environment comes from the Terraform workspace (`terraform.workspace`), not a variable. Run it
with `just e2e private`, which applies the stack then always destroys it.

[![Terraform Registry](https://img.shields.io/badge/registry-libre--devops-7B42BC?logo=terraform&logoColor=white)](https://registry.terraform.io/namespaces/libre-devops)

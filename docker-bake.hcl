variable "ASGARD_IMAGE" {
  default = "ghcr.io/chapeltech/asgard"
}

variable "ASGARD_TAG" {
  default = "latest"
}

variable "ASGARD_REVISION" {
  default = "unknown"
}

variable "BIFROST_REVISION" {
  default = "unknown"
}

group "default" {
  targets = ["kdc"]
}

group "test" {
  targets = ["kdc-test", "client"]
}

target "kdc" {
  dockerfile = "Dockerfile"
  target     = "kdc"
  tags       = ["asgard/kdc"]
  contexts = {
    bifrost = "../bifrost"
  }
}

target "kdc-test" {
  inherits = ["kdc"]
  target   = "kdc-test"
  contexts = {
    krb5_admin = "../krb5_admin"
  }
}

target "client" {
  dockerfile = "Dockerfile"
  target     = "client"
  tags       = ["asgard/client"]
  contexts = {
    bifrost = "../bifrost"
    krb5_admin = "../krb5_admin"
  }
}

target "publish" {
  inherits = ["kdc"]
  target   = "asgard"
  tags     = ["${ASGARD_IMAGE}:${ASGARD_TAG}"]
  labels = {
    "org.opencontainers.image.source" = "https://github.com/chapeltech/asgard"
    "org.opencontainers.image.revision" = "${ASGARD_REVISION}"
    "uk.chapeltech.asgard.bifrost.revision" = "${BIFROST_REVISION}"
  }
}

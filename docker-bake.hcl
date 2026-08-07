group "default" {
  targets = ["kdc-test", "client"]
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

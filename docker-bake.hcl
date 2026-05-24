group "default" {
  targets = ["kdc", "client"]
}

target "kdc" {
  dockerfile = "Dockerfile"
  target     = "kdc"
  tags       = ["asgard/kdc"]
  contexts = {
    bifrost = "../bifrost"
  }
}

target "client" {
  dockerfile = "Dockerfile"
  target     = "client"
  tags       = ["asgard/client"]
  contexts = {
    bifrost = "../bifrost"
  }
}

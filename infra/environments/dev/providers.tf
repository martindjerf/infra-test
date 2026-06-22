terraform {
  cloud {

    organization = "martin-corp"

    workspaces {
      name = "simple-terra-k8s-infra-dev"
    }
  }
}

provider "civo" {
  region = "LON1"
}
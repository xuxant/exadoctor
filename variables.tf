variable "vpc_id" {
  type    = string
  default = "vpc-0bc7f671"
}

variable "private_subnet_id" {
  type    = list(string)
  default = ["subnet-63cb7f2e", "subnet-5c937203", "subnet-66f91a47"]
}

variable "ondemand_desired_size" {
  type    = number
  default = 2
}

variable "ondemand_max_size" {
  type    = number
  default = 10
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "map_users" {
  type = list(object({
    group    = list(string)
    userarn  = string
    username = string
  }))
  default = [{
    group    = ["system:masters"]
    userarn  = ""
    username = "eks-cluster-user"
  }]
}

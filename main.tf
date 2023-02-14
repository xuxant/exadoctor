data "aws_region" "current" {}

data "aws_vpc" "current" {
  id = var.vpc_id
}

module "eks" {
  source                         = "terraform-aws-modules/eks/aws"
  cluster_name                   = "tidepool-test-cluster"
  cluster_endpoint_public_access = true

  vpc_id                    = var.vpc_id
  subnet_ids                = var.private_subnet_id
  create_aws_auth_configmap = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      resolve_conflicts = "OVERWRITE"
      addon_version     = "v1.10.0-eksbuild.1"
    }

  }


  cluster_security_group_additional_rules = {

    egress_nodes_ephemeral_ports_tcp = {
      description                = "To node 1025-65535"
      protocol                   = "-1"
      from_port                  = 0
      to_port                    = 0
      type                       = "egress"
      source_node_security_group = true
    }

    internal_access_cluster_endpoint = {
      description = "Access Cluster from within VPC."
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  node_security_group_additional_rules = {

    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }

    ingress_all = {
      description = "Node to Node all connection"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }

    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  self_managed_node_group_defaults = {
    disk_size           = 50
    suspended_processes = ["AZRebalance"]
    iam_role_additional_policies = {
      csi = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
    block_device_mappings = {
      sda1 = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size = 40
        }
      }
    }
  }


  self_managed_node_groups = {
    ondemand = {
      name            = "tidypool"
      min_size        = var.ondemand_desired_size
      max_size        = var.ondemand_max_size
      desired_size    = var.ondemand_desired_size
      create_iam_role = true


      bootstrap_extra_args = "--kubelet-extra-args '--node-labels=node.kubernetes.io/lifecycle=ondemand'"
      instance_type        = "c5.xlarge"
    }

  }

}

# resource "kubernetes_config_map" "aws_auth" {
#   metadata {
#     name      = yamldecode(module.eks.aws_auth_configmap_yaml).metadata.name
#     namespace = yamldecode(module.eks.aws_auth_configmap_yaml).metadata.namespace
#   }
#   data = {
#     "mapRoles" = yamldecode(module.eks.aws_auth_configmap_yaml).data.mapRoles
#     "mapUsers" = yamlencode(var.map_users)
#   }
# }

resource "kubernetes_namespace" "tidepool" {
  metadata {
    name = "tidepool"
  }
}

resource "kubernetes_namespace" "kafka" {
  metadata {
    name = "kafka"
  }
}

resource "helm_release" "tidypool" {
  name = "tidepool"

  chart             = "${path.module}/vendor/tidepool"
  namespace         = kubernetes_namespace.tidepool.metadata[0].name
  dependency_update = true

  values = [
    yamlencode({
      kafka = {
        configmap = {
          Brokers = "kafka-connect-kafka-brokers.tidepool:9092"
        }
        secretName = "kafka"
      },
      configmap = {
        Brokers = "kafka-connect-kafka-brokers.tidepool:9092"
      }
      secret = {
        data_ = {
          ".Addresses" = "mongo-mongodb.mongodb:27017"
          ".Username"  = "root"
          ".Password"  = "MongoRootPassword"
          ".Database"  = "tidepool"
        }
      }
    })
  ]

  depends_on = [
    helm_release.gloo,
    # helm_release.kafka,
    # helm_release.linkerd
  ]

}

resource "kubernetes_secret" "kafka" {
  metadata {
    name      = "kafka"
    namespace = "tidepool"
  }
  data = {
    Password = "helloWorld"
  }
}

resource "helm_release" "gloo" {
  name             = "gloo"
  chart            = "gloo"
  repository       = "https://storage.googleapis.com/solo-public-helm"
  create_namespace = true
  namespace        = "gloo-system"
}

resource "helm_release" "mongo" {
  name             = "mongo"
  chart            = "mongodb"
  repository       = "https://charts.bitnami.com/bitnami"
  create_namespace = true
  namespace        = "mongodb"

  values = [
    yamlencode({
      auth = {
        usernames    = ["tidepool"]
        passwords    = ["tidepool"]
        rootPassword = "MongoRootPassword"
        databases    = ["tidepool"]
      }
    })
  ]
}

# resource "helm_release" "kafka" {
#   name             = "kafka"
#   repository       = "https://charts.bitnami.com/bitnami"
#   chart            = "kafka"
#   create_namespace = true
#   namespace        = "kafka"

#   values = [
#     yamlencode({
#       auth = {
#         clientProtocol      = "sasl"
#         interBrokerProtocol = "sasl"
#         sasl = {
#           mechanisms           = "scram-sha-512"
#           interBrokerMechanism = "scram-sha-512"
#           jaas = {
#             clientUsers     = ["adminuser", "kafka"]
#             clientPasswords = ["helloWorld", "helloWorld"]
#           }
#         }
#       },
#       provisioning = {
#         enabled = true
#         topics = [
#           {
#             name              = "tidepool-kafka-connect-cluster-configs"
#             partitions        = 1
#             replicationFactor = 1
#             config = {
#               "max.message.bytes" = 64000
#               "flush.messages"    = 1
#             }
#           }
#         ]
#       }
#     })
#   ]
# }

resource "kubernetes_namespace" "kafka_operator" {
  metadata {
    name = "kafka-operator"
  }
  depends_on = [
    kubernetes_namespace.kafka
  ]
}

data "kubectl_file_documents" "stream" {
  content = file("${path.module}/vendor/kafka-operator/install.yaml")
}

resource "kubectl_manifest" "stream" {
  count     = length(data.kubectl_file_documents.stream.documents)
  yaml_body = element(data.kubectl_file_documents.stream.documents, count.index)
  depends_on = [
    kubernetes_namespace.kafka
  ]
}

resource "kubectl_manifest" "kafka" {
  override_namespace = "tidepool"
  yaml_body          = file("${path.module}/vendor/kafka/kafka.yaml")
  depends_on = [
    kubernetes_namespace.kafka
  ]
}


resource "helm_release" "keycloak" {
  name       = "keycloakx"
  chart      = "keycloakx"
  repository = "https://codecentric.github.io/helm-charts"
  # create_namespace = true
  namespace = kubernetes_namespace.tidepool.metadata[0].name
  version   = "2.0.0"
  values = [
    "${file("${path.module}/vendor/keycloakx/values.yaml")}"
  ]
}

variable "name_prefix" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "zone_id" { type = string }
variable "fqdn" { type = string }
variable "instance_type" {
  type    = string
  default = "t4g.small"
}

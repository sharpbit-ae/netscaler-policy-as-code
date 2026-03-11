output "vip_https" {
  value = "${var.vip}:443"
}

output "vip_http" {
  value = "${var.vip}:80"
}

output "backend_server" {
  value = "httpbin.org"
}

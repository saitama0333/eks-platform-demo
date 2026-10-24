locals {
  target_groups = {
    http  = aws_lb_target_group.http.arn
    https = aws_lb_target_group.https.arn
  }
}

resource "aws_security_group" "this" {
  name        = "${var.name}-ingress-nlb"
  description = "Public HTTP and HTTPS access to the ingress NLB"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_lb" "this" {
  name                             = "${var.name}-ingress"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = var.public_subnet_ids
  security_groups                  = [aws_security_group.this.id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false

  tags = var.tags
}

resource "aws_lb_target_group" "http" {
  name        = "${var.name}-http"
  port        = 30080
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = var.tags
}

resource "aws_lb_target_group" "https" {
  name        = "${var.name}-https"
  port        = 30443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}

resource "aws_autoscaling_attachment" "http" {
  count                  = var.attach_to_asg ? 1 : 0
  autoscaling_group_name = var.autoscaling_group_name
  lb_target_group_arn    = aws_lb_target_group.http.arn
}

resource "aws_autoscaling_attachment" "https" {
  count                  = var.attach_to_asg ? 1 : 0
  autoscaling_group_name = var.autoscaling_group_name
  lb_target_group_arn    = aws_lb_target_group.https.arn
}

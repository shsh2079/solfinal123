output "reservation_queue_url" { value = aws_sqs_queue.reservation.url }
output "reservation_queue_arn" { value = aws_sqs_queue.reservation.arn }
output "reservation_dlq_arn" { value = aws_sqs_queue.reservation_dlq.arn }

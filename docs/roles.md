
customer-view
customer-update






~/.ssh ❯❯❯ curl -X POST https://api.sangeethnipun.cf/send-email \
                 -H "Content-Type: application/json" \
                 -d '{
               "to": "maneehh1001@gmail.com",
               "subject": "Test Email from curl",
               "message": "Hello! This is a test email sent using curl."
             }'



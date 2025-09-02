for i in {1..40}; do curl -sk -o /dev/null -w "%{http_code} " https://shop.local:8443/; done; echo


#!/bin/bash
echo "SANDBOX_RUNTIME=${SANDBOX_RUNTIME:-unset}"
echo "--- proxy env"; env | grep -i -E '^(https?|all|no)_proxy=' | sed -E 's#//[^@/]*@#//<redacted>@#'
echo "--- curl direct P"; curl -s --noproxy '*' --max-time 3 http://127.0.0.1:47821/index.html; echo " rc=$?"
echo "--- curl direct Q"; curl -s --noproxy '*' --max-time 3 http://127.0.0.1:47822/index.html; echo " rc=$?"
echo "--- curl default P"; curl -s --max-time 3 http://127.0.0.1:47821/index.html; echo " rc=$?"
echo "--- nc P"; nc -z -w 2 127.0.0.1 47821; echo "rc=$?"
echo "--- nc Q"; nc -z -w 2 127.0.0.1 47822; echo "rc=$?"
echo "--- bb P"; bb -e '(println (try (slurp "http://127.0.0.1:47821/index.html") (catch Exception e (str "ERR " (.getMessage e)))))'
echo "--- bb Q"; bb -e '(println (try (slurp "http://127.0.0.1:47822/index.html") (catch Exception e (str "ERR " (.getMessage e)))))'
echo "--- curl outside (goes to proxy)"; curl -s --max-time 5 -o /dev/null -w '%{http_code}' https://github.com/; echo " rc=$?"

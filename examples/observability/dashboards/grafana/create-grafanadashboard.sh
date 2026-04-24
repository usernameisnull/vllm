#!/usr/bin/env bash
#kubectl create configmap vllm-performance-dashboard \
#  --from-file=performance_statistics.json \
#  -n insight-system
#
#kubectl create configmap vllm-query-dashboard \
#  --from-file=query_statistics.json \
#  -n insight-system

kubectl apply -f vllm-hybrid-grafanadashboard.yaml -n insight-system
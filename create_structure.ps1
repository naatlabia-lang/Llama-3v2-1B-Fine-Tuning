$dirs = @(
  "worker/src",
  "job/src",
  "shared/src",
  "deploy/k8s/helm/worker-chart",
  "deploy/k8s/helm/job-chart",
  "deploy/env/dev",
  "deploy/env/stg",
  "deploy/env/prod",
  "ci/github/workflows",
  "ci/templates",
  "scripts"
)
$dirs | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ | Out-Null }
"**/*" | Out-File -FilePath ".gitignore" -Encoding UTF8 -Force
"all:\n\t@echo Build all" | Out-File -FilePath "Makefile" -Encoding UTF8 -Force
"# Monorepo worker + job" | Out-File -FilePath "README.md" -Encoding UTF8 -Force
"Creado."

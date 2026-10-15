# POI: demanda, provisionamento e desempenho

Três aplicações web em Go, só backend, com perfis computacionais diferentes. O
repositório também tem a infraestrutura para fazer o deploy de uma delas numa VM
VirtualBox e medir como a demanda e os recursos provisionados afetam o desempenho
e a utilização.

| App | Porta | Endpoint principal | Perfil |
|---|---|---|---|
| `cpu` | 8081 | `GET /cpu?iter=N` | SHA-256 iterado N vezes; custo linear em N, sem memória nem disco |
| `mem` | 8082 | `GET /mem?mb=M&hold=ms` | aloca M MB, toca todas as páginas, varre o buffer e o segura por `hold` ms |
| `io` | 8083 | `GET /io?kb=K&fsync=1` | grava K KB, faz `fsync`, lê de volta e apaga o arquivo |

As três também expõem `GET /livez`, `GET /readyz`, `GET /info` (CPUs vistas pelo
processo, GOMAXPROCS, versão do Go) e `GET /metrics` no formato Prometheus, com
contador e histograma de requisições, requisições em andamento, CPU e RSS do
processo e heap do Go.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `cmd/{cpu,mem,io}/` | ponto de entrada de cada app |
| `internal/handler/` | handlers (`cpu.go`, `mem.go`, `io.go`, `health.go`) e testes |
| `internal/middleware/` | métricas Prometheus por requisição |
| `deploy/` | units systemd e scripts de deploy na VM |
| `load/load.js` | gerador de carga (k6) |
| `monitor/` | coletores de métricas (app, SO convidado, hipervisor, cgroup) |
| `experiments/` | configuração dos cenários, orquestrador e resultados brutos |
| `analysis/analyze.py` | tabela consolidada e gráficos |
| `lab/lab.sh` | etapas do dia no LCC |
| `docs/` | relatório final (`relatorio.pdf`), checklist do LCC e figuras |

## Requisitos

Para compilar, Go 1.26 ou mais novo. Para gerar carga, o
[k6](https://grafana.com/docs/k6/latest/set-up/install-k6/). A análise usa Python
3.9 ou mais novo, e o ensaio local usa Docker. Na VM não é preciso instalar nada,
porque os binários linux/amd64 são estáticos.

## Rodar localmente

```bash
make test
make build
./bin/cpu
```

Com a app rodando, `curl localhost:8081/cpu` em outro terminal responde com o
digest e o tempo gasto. Todas as variáveis de ambiente são opcionais:

| App | Variável | Padrão |
|---|---|---|
| todas | `PORT` | 8081 / 8082 / 8083 |
| cpu | `CPU_DEFAULT_ITER`, `CPU_MAX_ITER` | 200000, 20000000 |
| mem | `MEM_DEFAULT_MB`, `MEM_MAX_MB`, `MEM_DEFAULT_HOLD_MS`, `MEM_MAX_HOLD_MS` | 32, 1024, 100, 10000 |
| io | `IO_DIR`, `IO_DEFAULT_KB`, `IO_MAX_KB` | `$TMPDIR/poi-io`, 256, 65536 |

## Ensaio local com limites de recurso (Docker)

O mesmo orquestrador dos experimentos roda contra um container com `--cpus` e
`--memory` no lugar da VM. Usamos esse ensaio para calibrar parâmetros e testar a
coleta e a análise antes do laboratório. Os números dele não substituem os da VM.

```bash
make docker-build
experiments/run.sh experiments/scenarios-docker.conf
python3 -m venv analysis/.venv && analysis/.venv/bin/pip install -r analysis/requirements.txt
analysis/.venv/bin/python analysis/analyze.py experiments/results/docker-cpu
```

## Deploy na VM e experimentos no LCC

No Mac, `make lab-bundle` gera o `poi-lab.tar.gz`, com os binários linux/amd64, o
k6 e os scripts. No LCC, a VM é criada pela interface do VirtualBox, seguindo o
roteiro da disciplina, e depois o `lab/lab.sh` executa uma etapa por vez e confere o
resultado de cada uma. O passo a passo completo está em
[docs/checklist-lcc.md](docs/checklist-lcc.md).

| Comando | Etapa |
|---|---|
| `lab/lab.sh preflight` | confere ferramentas, host e VDI |
| `lab/lab.sh ssh` | configura a chave ssh |
| `lab/lab.sh deploy` | instala as apps como serviços systemd |
| `lab/lab.sh check` | testa tudo a partir do host |
| `lab/lab.sh calibrate` | ajusta o tempo de serviço e o cenário S4 |
| `lab/lab.sh restart-test` | confere que a app volta depois de religar a VM |
| `lab/lab.sh smoke` | roda um nível curto com todos os coletores |
| `lab/lab.sh run` | roda a varredura completa (`experiments/run.sh`) |
| `lab/lab.sh pack` | empacota os resultados |

Para cada cenário, o `experiments/run.sh` desliga a VM, aplica
`VBoxManage modifyvm --cpus/--memory`, liga a VM, espera a aplicação responder e
roda o k6 em cada nível de demanda. Enquanto isso, coleta as métricas da aplicação
(`/metrics`), do SO convidado (`vmstat` por ssh) e do hipervisor
(`VBoxManage metrics` e `/proc` do processo da VM). Os resultados ficam em
`experiments/results/<backend>-<app>/<cenário>/vus-NNN/`, e este comando gera a
tabela e os gráficos:

```bash
analysis/.venv/bin/python analysis/analyze.py experiments/results/vbox-cpu
```

O `run.sh` também aceita variáveis de ambiente para rodar só uma parte da
varredura: `ONLY="S1 S3"` escolhe os cenários, `LEVELS_ONLY="4 16"` escolhe os
níveis, `DURATION` e `WARMUP` mudam a duração de cada nível, `RESULTS_DIR` grava em
outra pasta e `DRY_RUN=1` só imprime os comandos, sem executar nada.

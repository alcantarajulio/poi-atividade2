# Divisão do trabalho

Cada pessoa fica responsável por uma metade da atividade e revisa a outra antes da
apresentação, porque os dois precisam saber explicar tudo na demonstração.

## Pessoa 1: aplicações e análise

Antes do laboratório, ler e entender as três apps (`internal/handler/cpu.go`,
`mem.go`, `io.go` e os `cmd/*/main.go`), rodar `make test` e as apps localmente e
refazer o ensaio em Docker (`experiments/run.sh experiments/scenarios-docker.conf`),
conferindo se os gráficos do `analysis/analyze.py` fazem sentido. A Pessoa 1 precisa
saber explicar por que cada app tem o perfil que tem e o que significa cada métrica
do `/metrics`.

No laboratório, acompanhar a varredura e conferir os resultados à medida que
saem, sem usar a máquina que está rodando a VM.

Na entrega, rodar o `analyze.py` sobre `experiments/results/vbox-cpu`, escolher as
figuras e escrever as seções "Aplicações desenvolvidas", "Resultados" e
"Interpretação e conclusões" do relatório.

## Pessoa 2: infraestrutura e experimentos

Antes do laboratório, ler o roteiro e o `docs/checklist-lcc.md`, revisar
`lab/lab.sh`, `deploy/`, `monitor/` e `experiments/run.sh` e rodar
`DRY_RUN=1 experiments/run.sh` para conhecer a sequência de comandos. Levar o
`poi-lab.tar.gz`, gerado com `make lab-bundle`.

No laboratório, executar o checklist do passo 0 ao 8: VM pela interface do
VirtualBox a partir do VDI, nginx, portas, ssh, deploy, calibração e a varredura
dos quatro cenários, com os prints de cada etapa.

Antes de sair do LCC, salvar no Drive o VDI e o pacote de resultados. Na entrega,
organizar os prints em `docs/prints/` e escrever as seções "Configuração da VM e
deploy" e "Como foram realizados os testes de stress" do relatório.

## Os dois

A demonstração em sala no LCC e a revisão cruzada do relatório são dos dois, e cada
um responde o próprio formulário. O Julio cuida do repositório e dos pushes.

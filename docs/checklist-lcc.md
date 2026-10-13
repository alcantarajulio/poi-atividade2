# Checklist do dia no LCC

Os passos de 1 a 4 seguem o roteiro do professor, pela interface do VirtualBox. A
partir do 5, o `lab/lab.sh` faz o deploy, a calibração e os experimentos, e confere
o resultado de cada etapa. Os passos marcados com (print) entram no relatório,
então tirem a captura de tela na hora.

A preparação leva uns 30 minutos. Depois vem a varredura automática, de cerca de
45 minutos, e durante ela a máquina não deve ser usada.

## Antes de ir

No Mac, `make lab-bundle` gera o `poi-lab.tar.gz`, com os binários linux/amd64, o
k6 e os scripts. Levem esse arquivo pelo Drive, num pendrive ou como release do
repositório.

```bash
make lab-bundle
```

## 0. Desempacotar e conferir o host

No LCC, na home:

```bash
mkdir -p ~/poi && tar -xzf poi-lab.tar.gz -C ~/poi && cd ~/poi
lab/lab.sh preflight
```

Todos os comandos a seguir rodam dentro de `~/poi`. O `preflight` confere o
VirtualBox, o k6 do pacote, os binários, os núcleos do host, o espaço em `/tmp` e o
VDI em `/local/uasc/images`. Nenhuma linha pode sair como FALHOU. O aviso de que a
VM ainda não existe é esperado nesse momento.

## 1. Criar a VM (roteiro, passos 1 a 3)

```bash
cp /local/uasc/images/ubuntu_server_2204_poi.vdi /tmp/
```

No VirtualBox, cliquem em Novo e configurem:

| Campo | Valor |
|---|---|
| Nome | `poi-vm` (os scripts usam esse nome) |
| Pasta da máquina | `/tmp` |
| Tipo e versão | Linux, Ubuntu (64-bit) |
| Processador e memória | 1 CPU, 1024 MB |
| Disco | usar um disco existente: `/tmp/ubuntu_server_2204_poi.vdi` |

(print de cada tela do assistente)

## 2. Ligar a VM e preparar o convidado (roteiro, passos 4 a 6)

Iniciem a VM pela interface e entrem com o usuário `osboxes` e a senha
`osboxes.org`. No console da VM:

```bash
sudo apt update && sudo apt install -y nginx openssh-server
sudo systemctl status nginx --no-pager
curl localhost:80
```

O `openssh-server` não está no roteiro, mas é ele que permite o deploy e a coleta de
métricas a partir do host. No host, `curl localhost:80` ainda não alcança a VM,
porque falta o redirecionamento de portas. (print do console e do teste no host)

Desliguem a VM com `sudo poweroff`.

## 3. Redirecionamento de portas (roteiro, passo 7)

Com a VM desligada, abram Configurações, Rede, Avançado, Redirecionamento de
portas, e criem as regras abaixo, todas TCP e com os campos de IP em branco:

| Nome | Porta do hospedeiro | Porta do convidado |
|---|---|---|
| ssh | 2222 | 22 |
| nginx | 8080 | 80 |
| cpu | 8081 | 8081 |
| mem | 8082 | 8082 |
| io | 8083 | 8083 |

O nginx usa a porta 8080 do host porque, no Linux, um usuário comum não pode abrir
portas abaixo de 1024, e o VirtualBox roda com o usuário de vocês. (print da tabela)

## 4. Testar o acesso pelo host (roteiro, passo 8)

Iniciem a VM de novo e, no host:

```bash
curl localhost:8080
```

A resposta deve ser a página do nginx. (print)

## 5. ssh, deploy e verificação

```bash
lab/lab.sh ssh
lab/lab.sh deploy
lab/lab.sh check
```

O `ssh` pede a senha `osboxes.org` uma vez, para o `ssh-copy-id`, e o `deploy` pede
de novo para o sudo da VM. O `check` testa o nginx e as três apps pelo host e
mostra o `/info` de cada uma, que deve ter `"num_cpu":1`. (print; é a demonstração
da aplicação rodando na VM)

## 6. Calibrar e testar o ciclo de reinício

```bash
lab/lab.sh calibrate
lab/lab.sh restart-test
```

O `calibrate` mede o `/cpu`, grava em `experiments/scenarios.conf` o `iter` que dá
~25 ms por requisição e ajusta o S4 ao número de núcleos do host. O `restart-test`
desliga a VM por ACPI, liga sem janela e espera a app voltar sozinha pelo systemd,
como o `run.sh` vai fazer a cada cenário.

## 7. Teste curto e varredura completa

```bash
lab/lab.sh smoke
lab/lab.sh run
```

O `smoke` roda um nível de 20 s e confere se cada coletor gravou o seu arquivo. As
linhas ATENÇÃO sobre o `host-vbox.csv` podem ser ignoradas: sem o Guest Additions,
o VirtualBox não exporta métricas do convidado, e a CPU e a memória da VM vistas
pelo host continuam no `host-proc.csv`. O `run` faz a varredura completa (4
cenários × 8 níveis) e grava um log em `experiments/`.

## 8. Antes de sair

```bash
lab/lab.sh pack
```

O `pack` gera `~/poi-resultados-<data>.tar.gz` com os resultados, o log e a
configuração usada. Esse arquivo e o VDI (`/tmp/ubuntu_server_2204_poi.vdi`, com a
VM desligada) precisam ir para o Drive antes de vocês saírem, porque o `/tmp` do
LCC é apagado. Em casa, os resultados entram no repositório e passam pelo
`analysis/analyze.py`.

## Demonstração para o professor

```bash
lab/lab.sh demo
```

O `demo` mostra a VM em execução, as vCPUs, a memória e os serviços vistos de
dentro dela por ssh, as três apps respondendo pelo host e as métricas em
`/metrics`. O que dizer em cada parte está em [apresentacao.md](apresentacao.md).

## Problemas comuns

Se o VirtualBox recusar o disco dizendo que o UUID já está registrado, é porque
outro usuário da máquina usou o mesmo VDI. Gerem um UUID novo para a cópia com
`VBoxManage internalcommands sethduuid /tmp/ubuntu_server_2204_poi.vdi` e
anexem de novo.

Se aparecer `Host key verification failed` depois de recriar a VM, rodem
`ssh-keygen -R "[localhost]:2222"`.

Se a VM ficar em estado `saved` ou `aborted` e o `modifyvm` falhar, rodem
`VBoxManage discardstate poi-vm`.

Se o `modifyvm` disser que a máquina está bloqueada, a VM ainda está desligando.
Esperem alguns segundos.

Se a VM não tiver internet para o `apt`, confiram se a interface 1 está em NAT
(`VBoxManage showvminfo poi-vm | grep NIC`). Sem internet o `openssh-server` não
instala. Nesse caso, sirvam os binários pelo host com `python3 -m http.server 9000`
e baixem na VM com `wget http://10.0.2.2:9000/bin/linux-amd64/cpu` (10.0.2.2 é o
endereço do host visto pelo NAT).

# Roteiro da demonstração (LCC)

A demonstração leva uns três minutos. A Pessoa 2 conduz a parte da VM, e a Pessoa
1, a das aplicações e dos resultados. Os dois precisam conseguir responder
perguntas sobre qualquer parte.

## 1. A VM (Pessoa 2)

Mostrar a janela do VirtualBox com a `poi-vm` rodando e, nas Configurações, 1 vCPU
e 1 GB, o VDI em `/tmp` e a tabela de redirecionamento de portas. Explicar que a VM
usa NAT, então o host só alcança os serviços dela pelas portas redirecionadas: 2222
para o ssh, 8080 para o nginx e 8081 a 8083 para as apps.

Rodar `lab/lab.sh demo`. As primeiras saídas mostram a VM em execução e, por ssh, o
número de vCPUs, a memória e os três serviços systemd ativos dentro dela. Explicar
que os serviços sobem sozinhos no boot e reiniciam se a aplicação cair, e que por
isso dá para religar a VM entre cenários sem intervenção.

## 2. As aplicações (Pessoa 1)

Nas saídas seguintes do `demo`, as três apps respondem pelo host. O `/cpu` faz
SHA-256 encadeado, e o tempo depende só da CPU. O `/mem` aloca e varre memória, e o
consumo cresce com as requisições simultâneas. O `/io` grava com `fsync`, e quase
todo o tempo é espera pelo disco.

Mostrar o `elapsed_ms` de cada uma e o trecho do `/metrics`, de onde saem a CPU e a
memória do processo durante os testes.

## 3. O experimento (Pessoa 1)

Se houver tempo, mostrar o `docs/figuras/docker-cpu/vazao_vs_demanda.png` do ensaio
local ou, se a varredura no LCC já tiver terminado, a mesma figura com os dados da
VM. A vazão cresce com a demanda até a CPU saturar. Quando as vCPUs dobram, o ponto
de saturação vai para a direita, e dobrar só a RAM (S3) não muda nada numa
aplicação limitada por CPU.

## Perguntas prováveis

Por que a carga vem de fora da VM? O gerador de carga também consome CPU. Dentro da
VM, ele competiria com a aplicação, e o resultado mediria os dois juntos.

Por que o think time de 0,5 s? Sem ele, cada usuário virtual mantém uma vCPU
ocupada sozinho, e o S1 já começaria saturado. Com ele, existe uma faixa de demanda
sem fila, e é nela que a comparação entre cenários faz sentido.

E se o S4 não chegar ao dobro do S2? As quatro vCPUs disputam o host com o próprio
VirtualBox e com o k6, que roda na mesma máquina. Além disso, vCPUs podem cair em
threads do mesmo núcleo físico.

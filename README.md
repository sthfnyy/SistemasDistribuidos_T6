# SistemasDistribuidos_T6

## Objetivo

Preparar um ambiente completo para avaliação de desempenho do Spring PetClinic Microservices usando Locust, com execução orientada por Docker Compose ou execução local equivalente quando o runtime do Docker não está disponível. O projeto foi organizado para permitir: iniciar a aplicação, aplicar carga em dois perfis distintos, automatizar repetições por cenários, coletar métricas, monitorar CPU, processar resultados e documentar a metodologia.

## Aplicação avaliada

A aplicação alvo é o repositório oficial do Spring PetClinic Microservices:
https://github.com/spring-petclinic/spring-petclinic-microservices

O projeto foi clonado em `petclinic/` e a execução foi validada com os serviços Spring Boot em execução com o JDK 17.

## Ambiente utilizado

- Sistema operacional: Windows 11
- Java: Microsoft OpenJDK 17
- Maven: wrapper do projeto (`./mvnw`)
- Python: 3.11
- Locust: 2.47.0
- Docker Compose: disponível na máquina, mas o ambiente atual não conseguiu iniciar imagens do Compose por ausência de daemon Docker Desktop/Engine; por isso, a validação funcional foi feita com os jars nativos do PetClinic

## Arquitetura do experimento

A infraestrutura de carga foi organizada em:

- `petclinic/`: aplicação Spring PetClinic Microservices
- `locust/`: arquivos do Locust (`locustfile.py`, `profiles.py`, `requirements.txt`)
- `scripts/`: automação de execução e processamento
- `results/raw/`: CSVs brutos produzidos pelo Locust e pelo monitor de CPU
- `results/processed/`: agregados finais
- `results/graphs/`: gráficos gerados a partir dos CSVs reais
- `evidencias/`: espaço para prints e evidências manuais

## Como executar o PetClinic

A forma oficial e mais simples do projeto é iniciar os serviços com Docker Compose. O arquivo `petclinic/docker-compose.yml` define os serviços principais, incluindo config-server, discovery-server, customers-service, vets-service, visits-service, api-gateway e demais componentes opcionais.

Comandos oficiais esperados:

```bash
cd petclinic
./mvnw clean install -DskipTests
docker compose up -d
```

No ambiente desta validação, o Docker Engine da máquina não ficou disponível, então os serviços foram iniciados diretamente com os jars Spring Boot:

```powershell
$env:JAVA_HOME='C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
cd petclinic
java -jar .\spring-petclinic-config-server\target\spring-petclinic-config-server-4.0.1.jar --server.port=8888
java -jar .\spring-petclinic-discovery-server\target\spring-petclinic-discovery-server-4.0.1.jar --server.port=8761
java -jar .\spring-petclinic-customers-service\target\spring-petclinic-customers-service-4.0.1.jar --server.port=8081
java -jar .\spring-petclinic-visits-service\target\spring-petclinic-visits-service-4.0.1.jar --server.port=8082
java -jar .\spring-petclinic-vets-service\target\spring-petclinic-vets-service-4.0.1.jar --server.port=8083
java -jar .\spring-petclinic-api-gateway\target\spring-petclinic-api-gateway-4.0.1.jar --server.port=8080
```

## Endpoints utilizados

Os endpoints confirmados na versão utilizada foram:

- GET `http://localhost:8080/api/customer/owners`
- GET `http://localhost:8080/api/customer/owners/{id}`
- GET `http://localhost:8080/api/vet/vets`
- POST `http://localhost:8080/api/customer/owners`

Observações importantes:

- O gateway expõe as APIs em prefixos `api/customer` e `api/vet`.
- O servidor de clientes expõe `GET /owners` e `POST /owners` internamente, mas o acesso externo foi validado via gateway em `/api/customer/owners`.
- O payload do POST realizado em produção foi validado como:

```json
{
  "firstName": "Ana",
  "lastName": "Silva",
  "address": "Rua A",
  "city": "Sao Paulo",
  "telephone": "11999999999"
}
```

## Instalação do Locust

```powershell
cd locust
python -m pip install -r requirements.txt
```

## Perfis de carga

Foram criados dois perfis independentes:

- `ReadProfile` com pesos:
  - GET `/api/customer/owners`: 45%
  - GET `/api/customer/owners/{id}`: 35%
  - GET `/api/vet/vets`: 15%
  - POST `/api/customer/owners`: 5%

- `WriteProfile` com pesos:
  - GET `/api/customer/owners`: 20%
  - GET `/api/customer/owners/{id}`: 20%
  - GET `/api/vet/vets`: 20%
  - POST `/api/customer/owners`: 40%

## Cenários experimentais

Os experimentos previstos são:

- Perfil Leitura e Perfil Escrita
- 30, 80 e 150 usuários
- 10 repetições por configuração
- Duração de 6 minutos por execução
- 1 minuto de aquecimento descartado

## Metodologia

A validação inicial foi feita com um teste curto para garantir o funcionamento da infraestrutura:

- 5 usuários
- 30 segundos
- perfil `ReadProfile`
- host `http://localhost:8080`
- CSV de saída em `results/raw/validacao/5-users/read_5_run01_*`

O teste curto não representa nenhum dos cenários finais e não usa descarte de aquecimento. Para os cenários completos, o Locust zera suas estatísticas aos 60 segundos e o processamento exige a confirmação desse reset no histórico. Os CSVs brutos são sempre preservados.

## Métricas coletadas

- tempo médio de resposta em ms
- P95 em ms
- vazão em req/s
- total de requisições
- taxa de falhas em %
- consumo de CPU de pelo menos dois serviços

## Monitoramento de CPU

Os serviços escolhidos para monitoramento de CPU foram:

- `customers-service`
- `vets-service`

O script `scripts/monitor_cpu.ps1` registra amostras durante toda a execução, inclusive no aquecimento, preservando a série bruta completa. No processamento, `scripts/process_results.py` localiza no histórico do Locust o snapshot imediatamente posterior ao reset e o último snapshot persistido. Somente amostras de CPU cujos timestamps estejam dentro desses mesmos limites, inclusive, entram nas médias finais. A quantidade considerada por serviço também é gravada em `results/processed/cpu.csv` e `results/processed/resumo.csv`.

## Como executar um teste individual

```powershell
cd locust
& 'C:\Users\sthef\AppData\Local\Programs\Python\Python311\python.exe' -m locust --headless --host http://localhost:8080 -u 5 -r 2 -t 20s --csv ..\results\raw\validacao\5-users\read_5_run01 ReadProfile
```

Também é possível usar o script automatizado:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_experiments.ps1 -Profile read -ShortValidation
```

## Como executar o benchmark completo

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_remaining_benchmark.ps1
```

Esse script pressupõe que `leitura/30/run01` já foi validado, executa somente as 59 runs restantes, retoma a partir de arquivos válidos, mantém `results/benchmark-progress.log`, limita retries e processa os resultados ao final.

## Estrutura dos resultados

```text
results/
├── raw/
│   ├── leitura/
│   │   ├── 30-users/
│   │   ├── 80-users/
│   │   └── 150-users/
│   └── escrita/
│       ├── 30-users/
│       ├── 80-users/
│       └── 150-users/
├── processed/
│   ├── resumo.csv
│   ├── medias.csv
│   └── cpu.csv
└── graphs/
```

## Resultados

As 60 runs previstas foram validadas: 10 repetições para cada combinação de perfil e número de usuários. `total_requests` é a soma das requisições pós-aquecimento das 10 runs; as demais métricas são médias entre runs.

| Perfil | Usuários | Runs válidas | Tempo médio (ms) | P95 (ms) | Vazão (req/s) | Requisições | Falhas (%) | CPU customers (%) | CPU vets (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Leitura | 30 | 10 | 346,400 | 1.353,5 | 22,675 | 67.760 | 0,394 | 28,017 | 0,256 |
| Leitura | 80 | 10 | 58,177 | 35,7 | 75,219 | 225.039 | 98,745 | 2,347 | 0,000 |
| Leitura | 150 | 10 | 69,090 | 167,5 | 137,733 | 411.963 | 99,434 | 2,295 | 0,015 |
| Escrita | 30 | 10 | 1.458,173 | 5.130,0 | 12,600 | 37.888 | 14,606 | 45,412 | 0,029 |
| Escrita | 80 | 10 | 34,847 | 12,7 | 76,763 | 229.407 | 98,752 | 5,113 | 0,000 |
| Escrita | 150 | 10 | 40,938 | 46,6 | 141,927 | 424.235 | 99,316 | 5,250 | 0,003 |

Os valores completos, sem arredondamento de apresentação, estão em `results/processed/resumo.csv`.

## Gráficos

Gráficos finais, gerados exclusivamente dos CSVs reais:

- `results/graphs/avg_response_time.png`
- `results/graphs/p95_response_time.png`
- `results/graphs/throughput.png`
- `results/graphs/failure_rate.png`
- `results/graphs/cpu_usage.png`

## Análise dos resultados

### Verificação de consistência

Foram inspecionados os 60 arquivos `*_failures.csv` e os 60 arquivos `*_stats.csv` das configurações finais. As contagens de falha por operação nos dois tipos de arquivo coincidem. Todos os erros registrados nos `*_failures.csv` têm o mesmo tipo: `HTTPError`, status HTTP 503 (`Service Unavailable`). Não apareceram outros status ou exceções nesses arquivos.

A taxa exibida na tabela principal é a média das taxas das dez runs, conforme `results/processed/resumo.csv`. As contagens abaixo são somas das dez runs; por isso, a razão entre as contagens somadas pode diferir ligeiramente da média entre runs.

| Perfil | Usuários | Requisições | Falhas | Sucessos | Falhas sobre os totais somados |
|---|---:|---:|---:|---:|---:|
| Leitura | 30 | 67.760 | 233 | 67.527 | 0,344% |
| Leitura | 80 | 225.039 | 222.216 | 2.823 | 98,746% |
| Leitura | 150 | 411.963 | 409.633 | 2.330 | 99,434% |
| Escrita | 30 | 37.888 | 5.624 | 32.264 | 14,844% |
| Escrita | 80 | 229.407 | 226.544 | 2.863 | 98,752% |
| Escrita | 150 | 424.235 | 421.334 | 2.901 | 99,316% |

### Principais erros e endpoints mais afetados

Somando as seis configurações, houve 1.285.584 falhas. A distribuição por operação foi:

| Operação | Falhas | Mensagem |
|---|---:|---|
| `GET /api/customer/owners` | 497.287 | HTTP 503 `Service Unavailable` |
| `GET /api/customer/owners/{id}` | 400.847 | HTTP 503 `Service Unavailable` |
| `GET /api/vet/vets` | 209.238 | HTTP 503 `Service Unavailable` |
| `POST /api/customer/owners` | 178.212 | HTTP 503 `Service Unavailable` |

`GET /api/customer/owners` acumulou mais falhas em números absolutos porque também é uma das operações de maior peso nos perfis. A comparação justa por taxa mostra que, dentro de cada cenário de 80 ou 150 usuários, **todas** as operações ficaram aproximadamente entre 98,69% e 99,45% de falha. Portanto, a indisponibilidade não ficou restrita a um único endpoint nem ao método POST.

Os logs do gateway confirmam respostas `503 SERVICE_UNAVAILABLE` e a mensagem `The requested service is currently unavailable. Please try again later.`. Há também registro explícito de `No servers available for service: vets-service`. Isso sustenta que pelo menos parte dos 503 foi produzida no gateway por indisponibilidade de destino. Entretanto, os artefatos preservados não demonstram a causa raiz comum de todas as falhas — por exemplo, não permitem escolher conclusivamente entre perda de registro/descoberta, queda dos serviços, saturação de algum componente ou outra falha de infraestrutura. Assim, a conclusão segura é indisponibilidade observada no gateway, não uma causa interna específica.

### Estatísticas por endpoint e comparação entre GET e POST

Os números a seguir foram recalculados diretamente dos `*_stats.csv`. O tempo médio é ponderado pelo número de requisições das dez runs; o P95 é a média dos P95 de cada run, seguindo a forma de consolidação usada no projeto.

| Perfil/usuários | Operação | Tempo médio (ms) | P95 médio (ms) | Taxa de falha somada |
|---|---|---:|---:|---:|
| Leitura/30 | GET owners | 545,571 | 1.846,5 | 0,415% |
| Leitura/30 | GET owner por id | 124,077 | 695,5 | 0,264% |
| Leitura/30 | GET vets | 48,988 | 137,1 | 0,295% |
| Leitura/30 | POST owner | 194,380 | 916,4 | 0,417% |
| Escrita/30 | GET owners | 2.931,369 | 6.590,0 | 14,855% |
| Escrita/30 | GET owner por id | 763,667 | 2.760,0 | 14,503% |
| Escrita/30 | GET vets | 45,593 | 155,0 | 14,830% |
| Escrita/30 | POST owner | 777,883 | 2.850,0 | 15,259% |
| Leitura/80 | GET owners / owner por id / vets / POST | 70,234 / 50,302 / 40,154 / 54,342 | 41,3 / 34,4 / 27,8 / 39,4 | 98,724% / 98,804% / 98,692% / 98,690% |
| Escrita/80 | GET owners / owner por id / vets / POST | 61,933 / 25,261 / 12,334 / 24,533 | 14,4 / 12,3 / 12,1 / 12,6 | 98,731% / 98,701% / 98,742% / 98,853% |
| Leitura/150 | GET owners / owner por id / vets / POST | 75,938 / 61,012 / 59,628 / 67,629 | 170,1 / 154,1 / 176,0 / 196,5 | 99,448% / 99,424% / 99,417% / 99,433% |
| Escrita/150 | GET owners / owner por id / vets / POST | 58,909 / 33,784 / 24,214 / 36,231 | 51,7 / 45,8 / 43,6 / 46,9 | 99,353% / 99,313% / 99,284% / 99,292% |

Em 30 usuários, onde ainda existe volume substancial de respostas bem-sucedidas, `GET /api/customer/owners` é a operação que mais degrada: no perfil de escrita, seu tempo médio ponderado sobe de 545,571 ms para 2.931,369 ms em relação ao perfil de leitura, e o P95 médio sobe de 1.846,5 ms para 6.590,0 ms. O POST também degrada no perfil de escrita (194,380 para 777,883 ms) e apresenta a maior taxa de falha desse cenário (15,259%), mas não é a operação mais lenta. `GET /api/vet/vets` é a menos afetada em latência com 30 usuários.

Em 80 e 150 usuários não é metodologicamente válido ordenar a degradação pela latência aparente: entre 98,69% e 99,45% das chamadas de cada endpoint falharam. Os CSVs do Locust agregam tempos de respostas bem-sucedidas e malsucedidas; eles não fornecem, nesses arquivos, percentis separados apenas para sucessos. Portanto, os tempos baixos desses cenários descrevem principalmente o caminho rápido de erro, e não o desempenho das operações concluídas com sucesso.

### Interpretação por cenário

- **Leitura/30:** cenário mais saudável, com 0,394% de falhas na média entre runs, 22,675 req/s e latência bem menor que escrita/30. `GET owners` ainda concentra a maior latência.
- **Escrita/30:** já apresenta degradação real: 14,606% de falhas, média de 1.458,173 ms e P95 de 5.130 ms. A maior proporção de POST coincide com maior pressão no `customers-service`, mas os dados por endpoint mostram que `GET owners`, e não o POST, foi a operação mais lenta.
- **Leitura/80 e escrita/80:** aproximadamente 98,75% das respostas falham com 503. A vazão nominal de cerca de 75–77 req/s mede sobretudo erros processados rapidamente; apenas 2.823 e 2.863 requisições, respectivamente, tiveram sucesso nas dez runs.
- **Leitura/150 e escrita/150:** a indisponibilidade se intensifica para aproximadamente 99,43% e 99,32%. Apesar da vazão nominal de cerca de 138–142 req/s, houve somente 2.330 e 2.901 sucessos nas dez runs. Esses cenários representam colapso funcional, não ganho de capacidade.

### Respostas às cinco perguntas do trabalho

1. **Como o aumento de usuários afeta o tempo de resposta?** De 30 usuários para cargas maiores não se observa uma melhora válida. Os tempos médios e P95 nominais caem em 80 usuários e voltam a subir parcialmente em 150, mas isso ocorre quando aproximadamente 99% das respostas são 503. Respostas de erro rápidas reduzem artificialmente média e P95. O experimento demonstra degradação de disponibilidade com o aumento da carga; não permite estimar a latência normal de sucesso em 80 e 150 usuários.

2. **Qual perfil apresenta maior vazão?** Em 30 usuários, leitura tem a maior vazão útil e nominal: 22,675 contra 12,600 req/s, com taxa de falha muito menor. Em 80 e 150, escrita tem a maior vazão **nominal** (76,763 e 141,927 req/s, contra 75,219 e 137,733), mas quase todo esse volume é de respostas 503; logo, não representa maior capacidade útil. Subtraindo `Failures/s` de `Requests/s` nos agregados, as vazões médias aproximadas de sucesso são apenas 0,944 e 0,779 req/s em leitura/80 e leitura/150, e 0,958 e 0,971 req/s em escrita/80 e escrita/150, contra 22,597 req/s em leitura/30. Considerando serviço entregue com sucesso, o resultado favorece claramente leitura/30.

3. **Quais operações apresentam maior degradação?** No intervalo comparável de 30 usuários, `GET /api/customer/owners` apresenta a maior degradação de latência, sobretudo em escrita/30 (2.931,369 ms de média ponderada e P95 médio de 6.590 ms). `POST /api/customer/owners` também degrada e tem a maior taxa de falha de escrita/30 (15,259%). Em 80/150, todas as operações degradam principalmente em disponibilidade, com cerca de 99% de falhas, e não há base para comparar latência de sucesso entre elas.

4. **Como o consumo de CPU varia entre os cenários?** O `customers-service` atinge as maiores médias em escrita/30 (45,412%) e leitura/30 (28,017%). Em leitura/80 e leitura/150 cai para 2,347% e 2,295%; em escrita/80 e escrita/150 fica em 5,113% e 5,250%. O `vets-service` permanece próximo de zero em todos os consolidados. A queda de CPU coincide com os 503 rápidos e é compatível com pouco trabalho chegando aos serviços monitorados, mas CPU isoladamente não prova a causa raiz da indisponibilidade.

5. **Qual cenário apresenta maior taxa de falhas?** Leitura/150, com média de 99,434% entre runs. Em seguida aparecem escrita/150 (99,316%), escrita/80 (98,752%) e leitura/80 (98,745%).

### Limitações do experimento

- Média, P95 e vazão do Locust incluem respostas de erro; não há, nos CSVs gerados, distribuição de latência separada somente para sucessos.
- Os perfis usam pesos diferentes. Contagens absolutas entre endpoints refletem tanto confiabilidade quanto frequência de chamada.
- Os logs permitem confirmar os 503 emitidos pelo gateway, mas não contêm evidência suficiente para atribuir uma única causa raiz a todas as indisponibilidades.
- CPU foi monitorada apenas em `customers-service` e `vets-service`; não há série equivalente de CPU do gateway, discovery-server, banco ou máquina completa.
- A amostragem de CPU varia entre runs e é especialmente esparsa em escrita/30 (39 amostras por serviço somadas nas dez runs).
- A execução local com jars, em uma única máquina, limita a generalização para um ambiente distribuído ou baseado em containers.
- As métricas consolidadas são médias entre runs; médias de percentis não equivalem ao percentil de todas as observações reunidas.

## Conclusão

O benchmark completou 60 runs válidas, sem runs definitivamente perdidas. O ambiente sustentou leitura/30 com baixa taxa de falhas, enquanto escrita/30 já apresentou latência alta e 14,606% de falhas. Em 80 e 150 usuários, todos os endpoints e ambos os perfis foram dominados por HTTP 503 próximo de 99%. Os menores tempos e a maior vazão nominal nessas cargas são artefatos de respostas de erro rápidas e não indicam melhora. O resultado seguro é a identificação de um limite operacional entre 30 e 80 usuários neste ambiente. A causa raiz desse limite não pode ser determinada apenas com os artefatos coletados, embora os logs confirmem que o gateway respondeu por indisponibilidade de serviço.

## Vídeo

COLOQUE_AQUI_O_LINK_DO_VIDEO

## Validação inicial executada

A seguinte validação inicial foi concluída com sucesso:

- PetClinic levantado localmente com os jars do projeto
- endpoints reais confirmados via gateway
- Locust 2.47.0 validado em modo headless com 5 usuários e 20 segundos
- 89 requisições no CSV agregado, 0 falhas e 4,945 req/s
- CSVs gerados em `results/raw/validacao/5-users/`
- 9 amostras de CPU para `customers-service` e 9 para `vets-service` em `results/raw/cpu_validation_current.csv`

## Observações e problemas encontrados

- O repositório oficial usa Docker Compose como fluxo padrão, mas o ambiente desta máquina não possui serviço Docker operativo para subir os containers. Por isso, a validação inicial foi feita com execução direta dos jars do projeto.
- O gateway foi validado em `http://localhost:8080` e os endpoints do PetClinic foram confirmados via `api/customer` e `api/vet`.
- O payload do POST foi validado com o contrato real da aplicação e não foi inventado.
- Serviços confirmados por `GET /actuator/health` com HTTP 200: config-server (8888), discovery-server (8761), api-gateway (8080), customers-service (8081), visits-service (8082) e vets-service (8083).
- O Eureka listou `API-GATEWAY`, `CUSTOMERS-SERVICE`, `DISCOVERY-SERVER`, `VETS-SERVICE` e `VISITS-SERVICE` como `UP`. Portanto, o gateway depende do discovery-server no modo atual; sem Eureka, a correção mínima é iniciar primeiro config-server e discovery-server e aguardar seus health checks antes dos serviços de domínio e do gateway.
- URL base validada: `http://localhost:8080`.
- Endpoints confirmados no teste curto: `GET /api/customer/owners`, `GET /api/customer/owners/{id}`, `GET /api/vet/vets` e `POST /api/customer/owners`; todos tiveram zero falhas no CSV.
- O comando `python` não estava disponível no `PATH` da sessão restrita. O teste foi executado com o caminho absoluto do Python 3.11 indicado abaixo.
- O acesso a `Win32_Process` via CIM foi negado sem elevação. `monitor_cpu.ps1` foi ajustado para descobrir os JVMs pelas portas em `netstat`, sem exigir CIM.
- Um arquivo curto anterior estava armazenado incorretamente em `results/raw/leitura/30-users/`; ele foi preservado como evidência bruta, mas é excluído do processamento para não ser apresentado como cenário completo.
- Durante o benchmark, logs DEBUG do gateway reduziram o espaço livre. Os arquivos existentes foram preservados com compactação NTFS e as retomadas usaram níveis de logging de framework reduzidos. O benchmark foi interrompido preventivamente uma vez durante `leitura/150/run03` e retomado a partir das runs válidas.
- A tentativa parcial de `leitura/150/run03` não permaneceu como conjunto separado: os arquivos com nomes padrão foram substituídos quando a mesma run foi retomada. O conjunto final da run é válido, mas essa é uma limitação de preservação da tentativa parcial.
- Em escrita/30, a coleta pós-aquecimento ficou esparsa (39 amostras por serviço somadas nas 10 runs). Nenhuma média foi preenchida artificialmente; `results/processed/cpu.csv` registra as contagens efetivamente utilizadas.

## Reprodução exata da validação curta

Execute a partir da raiz do repositório, com os serviços já iniciados em background:

```powershell
$pythonExe = 'C:\Users\sthef\AppData\Local\Programs\Python\Python311\python.exe'
$cpu = Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PWD 'scripts\monitor_cpu.ps1'),'-Profile','read','-Users','5','-Run','1','-DurationSeconds','20','-SampleIntervalSeconds','2','-OutputCsv','results/raw/cpu_validation_current.csv') -PassThru -WindowStyle Hidden
Push-Location locust
& $pythonExe -m locust --headless --host http://localhost:8080 -u 5 -r 2 -t 20s --csv ..\results\raw\validacao\5-users\read_5_run01 ReadProfile
Pop-Location
if (-not $cpu.WaitForExit(30000)) {
    Stop-Process -Id $cpu.Id -Force
    throw 'A coleta de CPU excedeu o limite de 30 segundos.'
}
& $pythonExe .\scripts\process_results.py
```

Cada comando tem término definido: Locust e coleta de CPU duram 20 segundos, e a espera pelo monitor é limitada a 30 segundos.

## Execução completa confirmada antes do benchmark total

Esta seção registra a validação histórica feita antes do benchmark total. Posteriormente, as outras 59 execuções foram concluídas; os resultados consolidados estão na seção `Resultados`.

- período total: 360 segundos
- aquecimento descartado: primeiros 60 segundos
- período medido no histórico CSV: 297 segundos, diferença entre o snapshot pós-reset `1792635111` e o último snapshot efetivamente persistido `1792635408`; esse valor decorre dos snapshots disponíveis e não de uma suposição de 300 segundos exatos
- confirmação do descarte: contador agregado caiu de 1.538 para 20 entre os snapshots `1792635110` e `1792635111`, após o marcador `WARMUP_RESET_COMPLETED seconds=60`
- requisições persistidas após o reset: 8.521
- falhas: 0 (0%)
- tempo médio: 40,624 ms
- P95: 100 ms
- vazão: 28,653 req/s
- CPU média pós-aquecimento de `customers-service`: 14,717%
- CPU média pós-aquecimento de `vets-service`: 1,094%
- amostras de CPU consideradas depois do descarte: 53 por serviço
- coleta bruta de CPU preservada: aproximadamente 359 segundos, com 64 amostras por serviço; as 11 amostras anteriores à janela útil foram mantidas no CSV, mas excluídas das médias

Os CSVs brutos estão em `results/raw/leitura/30-users/`, a CPU em `results/raw/cpu_read_30_run01.csv`, os agregados em `results/processed/` e os gráficos de leitura em `results/graphs/`.

O console do Locust mostrou 8.530 requisições durante o encerramento, enquanto o CSV final persistiu 8.521. As métricas documentadas usam exclusivamente o CSV persistido, para manter reprodutibilidade.

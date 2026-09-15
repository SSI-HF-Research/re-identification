# Benchmarks — Cenários A, B, C

## Pré-requisitos
- Rede já no ar, todos os chaincodes deployados e o comitê (EC1/EC2/EC3)
  já registrado via `setup-committee.sh`
- `flock`, `openssl`, `node`, `python3`, `jq`, `awk`, GNU `date` (suporta `+%s%N`)
- Scripts colocados em `scripts/bench/` dentro do seu projeto, ao lado de
  `invokeCC.sh`, `queryCC.sh`, `utils.sh`, `envvar.sh` e da pasta `scripts/test/`
  (`crypto-helper.js`, `ec-sign.js`)

## Premissas assumidas (confirmar/ajustar antes de rodar)
1. **Nomes de chaincode** em `00-config.sh` — kebab-case, copiados do seu
   `reid-study.sh` (`identity-mapping`, `warehouse-mapping`, `study-mapping`,
   `study-reidentification`, `warehouse-reidentification`). Ajuste se
   divergir do que está de fato commitado.
2. **`CAPTURE_TXID_FILE`** — o Cenário B depende desse mecanismo em
   `invokeCC.sh` pra capturar o `reqId` retornado por `CreateReIDRequest`
   (que usa `ctx.stub.getTxID()`), exatamente como já é feito em
   `reid-study.sh` / `invoke_capture_txid`. Se o mecanismo real for
   diferente, ajustar a extração de `req_id` em `scenario-b-reid.sh`.
3. Datamarts/estudos usados nos benchmarks são fictícios
   (`bench-study`, `bench-dm-N`) — não colidem com dados reais, mas rodar
   num ambiente de teste, não em produção.

## Cenários

| Script | O que mede | Parâmetros principais |
|---|---|---|
| `scenario-a-ingest.sh` | M1, M3, M5 (parcial), M6 | `N_PATIENTS`, `BATCH_SIZE`, `CONCURRENCY` |
| `scenario-b-reid.sh` | M4, M5 (parcial), M6 | `REPEAT`, `CONCURRENCY_REID` |
| `scenario-c-load.sh` | M2, M6 | `LEVELS`, `OPS_PER_LEVEL` |

Rodar individualmente:
```bash
N_PATIENTS=100 BATCH_SIZE=20 CONCURRENCY=8 ./scripts/bench/scenario-a-ingest.sh
REPEAT=30 CONCURRENCY_REID=1 ./scripts/bench/scenario-b-reid.sh
LEVELS="1 2 4 8 16" OPS_PER_LEVEL=50 ./scripts/bench/scenario-c-load.sh
```

Ou tudo de uma vez (com os defaults de `00-config.sh`):
```bash
./scripts/bench/run-all.sh
```

## Analisando os resultados

Cada cenário grava um ou mais CSVs em `bench-results/` no formato
`label,duration_ms,success,timestamp`. Para agregar em estatísticas:

```bash
python3 scripts/bench/analyze.py bench-results/scenario-a_N100_batch20_conc8.csv --warmup 5
```

`--warmup N` descarta as N primeiras amostras de cada label antes de
calcular média/percentis — recomendado usar N=5 a 10 pra amortecer o
efeito de conexão gRPC fria / JIT do Node no início da execução.

**Recomendações metodológicas:**
- Rodar cada configuração pelo menos ~30 vezes (ajustar `REPEAT`/`OPS_PER_LEVEL`)
  antes de reportar percentis com confiança
- Mudar uma variável por vez (N, tamanho de lote, concorrência) — não
  combinar mudanças na mesma rodada, senão não dá pra atribuir causa ao efeito
- Reportar p50/p95/p99, não só a média — a cauda longa é o que geralmente
  importa em sistemas distribuídos
- Ambiente controlado: mesma máquina, nada mais competindo por CPU durante
  a medição, documentar a spec de hardware no artigo

## Mapeamento pra Seção 7 do artigo

| Placeholder no LaTeX | Métrica | Fonte |
|---|---|---|
| `pseudoanonymization time for each level` | M1 | `scenario-a_*.csv`, labels A1-A4 |
| `total time for re-identification process` | M4 | `scenario-b_*.csv`, labels B1-B9 e `B_TOTAL_reid_process` |
| `transaction latency, max throughput` | M2 | `scenario-c-throughput-summary.csv` |
| `total time for identity-wp-sp-reid` | M4+M5 | soma de A (até WP/SP) + `B_TOTAL_reid_process` |
| `reading/writing on each channel, each pdc (time)` | M3 | implícito em cada label — cada um já é uma leitura/escrita isolada de uma PDC específica |
| `how scalable — multiple processes running` | M6 | variar `N_PATIENTS`/`BATCH_SIZE`/`CONCURRENCY` (Cenário A) e `LEVELS` (Cenário C) |

## O que NÃO está coberto aqui (fora de escopo destes scripts)

- Métricas de infraestrutura (CPU/memória dos peers/orderer sob carga) —
  usar `docker stats` durante o Cenário C, ou habilitar
  `CORE_METRICS_PROVIDER=prometheus` no `docker-compose.yaml` pra métricas
  nativas do Fabric (endorsement duration, block cut time etc.), que
  complementam mas não substituem os CSVs acima
- Testes de carga formais via Hyperledger Caliper — os scripts aqui
  cobrem o suficiente pro escopo da dissertação; Caliper só valeria a
  pena se quiser citar throughput com uma ferramenta padrão da literatura

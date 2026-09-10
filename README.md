# Fabric PoC — Fase 0: rede com 2 channels

PoC do artigo: valida a separação `channel-l1` (pseudônimo de warehouse) /
`channel-l2` (pseudônimo de estudo), sem system channel (modelo Fabric >= 2.3,
igual ao `test-network` atual).

## Topologia

| Channel | Orgs membro | PDCs previstas (fase 1/2) |
|---|---|---|
| `channel-l1` | OrgIM, OrgL1PI, OrgHDW | Bind_Mapping, L1_Mapping, L1_Re-Identification |
| `channel-l2` | OrgSC, OrgL2PI | L2_Mapping, L2_Re-Identification |

`OrgRO` (Re-Identification Official) e `OrgMO` (Medical Officer) entram na
Fase 4 (RO precisa ser membro dos dois channels).

## Pré-requisitos

- Docker + Docker Compose v2 (`docker compose`, não `docker-compose`)
- Binários do Fabric (`cryptogen`, `configtxgen`, `osnadmin`, `peer`) e as
  imagens docker `hyperledger/fabric-peer:2.5` e `hyperledger/fabric-orderer:2.5`

Forma mais rápida de obter os binários — script oficial da Hyperledger:

```bash
curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
chmod +x install-fabric.sh
./install-fabric.sh docker binary
```

Isso cria uma pasta `bin/` (binários) e `config/` na pasta onde você rodar.
Copie a pasta `bin/` para a raiz deste projeto (`fabric-poc/bin`), ou ajuste
o `PATH` nos scripts para apontar pra onde você a deixou.

Confira as portas livres no host: `7050`, `7053`, `7051`, `8051`, `9051`,
`10051`, `11051`.

## Estrutura

```
fabric-poc/
  network/
    crypto-config.yaml     # orgs -> cryptogen
    configtx.yaml           # perfis dos 2 channels -> configtxgen
    docker-compose.yaml     # orderer + 5 peers
    crypto-config/          # gerado (não versionar)
    channel-artifacts/      # gerado (não versionar)
  scripts/
    envvar.sh               # troca de identidade (setOrgIM, setOrgHDW, ...)
    01-generate.sh           # cryptogen + configtxgen
    02-start.sh               # docker compose up
    03-create-channels.sh      # osnadmin channel join (orderer)
    04-join-peers.sh            # peer channel join (cada org) + checagem de isolamento
    network.sh                   # orquestrador: up / down / status
```

## Uso

```bash
cd fabric-poc
./scripts/network.sh up
```

Isso executa, em ordem: gera crypto material e blocks -> sobe containers ->
associa orderer aos 2 channels -> cada peer entra no seu channel -> imprime
`peer channel list` de cada org pra você conferir visualmente o isolamento.

Saída esperada no final (resumida):

```
--- OrgIMMSP (localhost:7051) esta nos channels: ---
Channels peers has joined:
channel-l1

--- OrgSCMSP (localhost:10051) esta nos channels: ---
Channels peers has joined:
channel-l2
```

Se `OrgIM` aparecer em `channel-l2` (ou vice-versa), algo está errado na
configuração — isso não deve acontecer dado o `configtx.yaml`.

Para derrubar tudo e limpar:

```bash
./scripts/network.sh down
```

Para só checar containers:

```bash
./scripts/network.sh status
```

## Criterio de "pronto" da Fase 0

- [ ] `network.sh up` sobe sem erro
- [ ] `peer channel list` confirma que `OrgIM`, `OrgL1PI`, `OrgHDW` só veem `channel-l1`
- [ ] `peer channel list` confirma que `OrgSC`, `OrgL2PI` só veem `channel-l2`
- [ ] (teste extra) tentar `setOrgIM` e depois consultar algo em `channel-l2`
      deve falhar — a org nem está no channel, então não há como

## Próximo passo (Fase 1)

Chaincode do `channel-l1`: PDCs `Bind_Mapping` (IM, L1PI) e `L1_Mapping`
(L1PI, HDW), com as funções `get_bind`, `create_bind`, `register_l1`, `get_l1`,
implementando o fluxo A1-A8 do artigo com PII simulado (string qualquer).

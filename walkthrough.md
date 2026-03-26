„Modernisierung der GenAI-Hosting-Plattform“

zielbild fpr zukünftige GenAI-Hosting definiert und ein Migrationskonzept für die Hosting-Plattform
entwickelt werden. 
Das technische Umfeld umfasst Azure AKS, Azure Networking und Security,
Kubernetes Networking (CNI, Ingress, Network Policies), Linux, TCP/IP, DNS sowie den Einsatz
von Terraform und Infrastructure as Code. 

Die Plattform bildet die Basis für interne
Entwicklerteams und unterstützt eine vorstrukturierte Entwicklung inklusive CI/CD-Prozessen.
Die Umgebung besteht aus etwa 20 Clustern verschiedener Produkttypen, darunter Shared
Kubernetes Cluster. 

Herausforderungen bestehen insbesondere in der Netzwerkarchitektur,
dem Routing, der Trennung von Public und Private Endpoints sowie der Integration von
Monitoring- und Security-Konzepten. 

 * API Server VNet Intergation - recommended by Microsoft once it is GA

Die beauftragte Leistung umfasst die Analyse, Konzeption
und Entwicklung im vorgenannten Projekt mit folgenden (Teil-)Leistungen:


- Durchführung einer Status-quo-Analyse der bestehenden GenAI-Hosting-Plattform mit
Schwerpunkt auf der Netzwerkarchitektur, einschließlich Routing, VNet, Private Endpoints,
Application Gateway in Public Azure sowie der Abgrenzung zu Public Internet und Private
Netzwerken, um Verbesserungspotenziale hinsichtlich Performance, Sicherheit und
Skalierbarkeit zu ermitteln.


- Definition des Zielbildes für das zukünftige GenAI-Hosting unter Berücksichtigung der
Integration von Kubernetes (AKS), Shared Clustern, CI/CD-Prozessen und der Anforderungen der
internen Entwicklungsteams als Referenz für die Transformation.


- Entwicklung eines Migrationskonzepts für die Hosting-Plattform zur Migration bestehender
Anwendungen und Cluster in die Azure-Umgebung, einschließlich Ausarbeitung von
Integrationskonzepten, Berücksichtigung von Netzwerk- und Security-Aspekten wie Network
Policies, Monitoring, Umgang mit Packet Loss, Alternativen zu bestehenden Lösungen sowie
Planung von Prototyping- und Proof-of-Concept-Phasen zur Leistungsbewertung.


- Erstellung eines Umsetzungsplans mit Beschreibung der einzelnen Migrationsschritte, der
Einbindung der Entwicklungsteams und der Sicherstellung des laufenden Betriebs während des
Transformationsprozesses.


Die Leistung erfordert fundierte Kenntnisse im Bereich Networking, insbesondere im Kontext
von Kubernetes, Azure AKS, Infrastructure as Code und komplexen Netzwerkarchitekturen.


-----------------------------------------
Policy BPF Issue

Impact statement
We hit the bpf-policy-map-max limit for cilium, and with this most Network communication in our cluster is blocked

When did the problem start?
{'dateTime':'2026-01-13T23:00:00+00:00','timezone':'W. Europe Standard Time','dontKnowTime':false}

Is this problem related to Linux or Windows node pool?
linux

Description
We hit the cilium_bpf_map_pressure. limit  (bpf-policy-map-max in the collium config)
This blocks then all traffic from  namespaces / pods to other pods or the outside
-------------


az aks create --node-count 1 \
  --resource-group rg-test-tmp \
    --name aks-test-tmp \
    --enable-managed-identity \
    --enable-gateway-api \
    --enable-application-load-balancer \
    --network-plugin azure \
    --vnet-subnet-id /subscriptions/ca14d2a8-0e05-4312-91bc-d7112ffa2e3d/resourceGroups/rg-test-tmp/providers/Microsoft.Network/virtualNetworks/vnet-test-tmp/subnets/snet-test-tmp-01 \
    --dns-service-ip 172.27.0.10 \
    --service-cidr 172.27.0.0/16 \
	--network-plugin-mode overlay \
	--network-dataplane cilium 
	
 "linuxProfile": {
    "adminUsername": "azureuser",
    "ssh": {
      "publicKeys": [
        {
          "keyData": "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCV+lFkV9idyhA/6n/zIr9L4wWcJClm90fCtwbB1DBHCqO6goDCuTMQa8ITfcY719llkcZzbOgtDJIFyQ6hSsY7ovw62go3ANaBpCVc0Onv1OCMZ3VpiC6ZrSkfkDoO4kC7OK8UBOXbKwS3XYRWJ6NygXfl5z/074eTulpTamLNZUpO3Eq3XriUbeFuY0T6pLpWHI44aVvTr1yMZvPT++0241hu4Sv6apdcHLA/3hcXB7QmnTFfc8EGlsfXRv/TlJtsxIEWK3tOhOHvdxj3npuKaWx9YvzYydZRbqEoGB6yIL1aBQuXcteu4AIwRrzdOWWBkMixTfKW7jEt116JHp7b"
        }
      ]
    }
  },
  
# SQL
testadmin
12database!

# Manifest api
```yml
apiVersion: v1
kind: Secret
metadata:
  name: sqlpassword
type: Opaque
stringData:
  password: "12database!"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    run: api
  name: api
spec:
  replicas: 1
  selector:
    matchLabels:
      run: api
  template:
    metadata:
      labels:
        run: api
    spec:
      containers:
      - image: fasthacks/sqlapi:1.0
        name: api
        ports:
        - containerPort: 8080
          protocol: TCP
        env:
        - name: SQL_SERVER_USERNAME
          value: "testadmin
        - name: SQL_SERVER_FQDN
          value: "tmpsql.database.windows.net"
        - name: SQL_SERVER_PASSWORD
          valueFrom:
            secretKeyRef:
              name: sqlpassword
              key: password
      restartPolicy: Always
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  type: LoadBalancer
  ports:
  - port: 8080
    targetPort: 8080
  selector:
    run: api
```
--------------------------------
#Setup ALB


$ALB_SUBNET_ID="/subscriptions/ca14d2a8-0e05-4312-91bc-d7112ffa2e3d/resourceGroups/rg-test-tmp/providers/Microsoft.Network/virtualNetworks/vnet-test-tmp/subnets/snet-alb-tmp"
$IDENTITY_RESOURCE_NAME="applicationloadbalancer-aks-test-tmp"
$mcResourceGroupId="/subscriptions/ca14d2a8-0e05-4312-91bc-d7112ffa2e3d/resourceGroups/MC_rg-test-tmp_aks-test-tmp_westeurope"
$principalId="9f824eab-76ae-431e-990f-381aeffd00d5"

# Delegate AppGw for Containers Configuration Manager role to AKS Managed Cluster RG
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $mcResourceGroupId --role "fbc52c3f-28ad-4303-a892-8a056630b8f1" 

# Delegate Network Contributor permission for join to association subnet
az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $ALB_SUBNET_ID --role "4d97b98b-1d4f-4787-a291-c67834d212e7" 
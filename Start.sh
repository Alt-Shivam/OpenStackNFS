#letsStart
cd /opt/
set -xe

git clone https://opendev.org/openstack/openstack-helm-infra.git
git clone https://opendev.org/openstack/openstack-helm.git


cd /opt/openstack-helm


sudo -H -E pip3 install --upgrade pip
sudo -H -E pip3 install \
  -c${UPPER_CONSTRAINTS_FILE:=https://releases.openstack.org/constraints/upper/${OPENSTACK_RELEASE:-stein}} \
  cmd2 python-openstackclient python-heatclient --ignore-installed


export HELM_CHART_ROOT_PATH=/opt/openstack-helm-infra/
export OSH_INFRA_PATH=/opt/openstack-helm-infra/


sudo -H mkdir -p /etc/openstack
sudo -H chown -R $(id -un): /etc/openstack
FEATURE_GATE="tls"; if [[ ${FEATURE_GATES//,/ } =~ (^|[[:space:]])${FEATURE_GATE}($|[[:space:]]) ]]; then
  tee /etc/openstack/clouds.yaml << EOF
  clouds:
    openstack_helm:
      region_name: RegionOne
      identity_api_version: 3
      cacert: /etc/openstack-helm/certs/ca/ca.pem
      auth:
        username: 'admin'
        password: 'password'
        project_name: 'admin'
        project_domain_name: 'default'
        user_domain_name: 'default'
        auth_url: 'https://keystone.openstack.svc.cluster.local/v3'
EOF
else
  tee /etc/openstack/clouds.yaml << EOF
  clouds:
    openstack_helm:
      region_name: RegionOne
      identity_api_version: 3
      auth:
        username: 'admin'
        password: 'password'
        project_name: 'admin'
        project_domain_name: 'default'
        user_domain_name: 'default'
        auth_url: 'http://keystone.openstack.svc.cluster.local/v3'
EOF
fi


make -C ${HELM_CHART_ROOT_PATH} helm-toolkit
sleep 3

: ${OSH_EXTRA_HELM_ARGS_INGRESS:="$(./tools/deployment/common/get-values-overrides.sh ingress)"}
sleep 3

make -C ${HELM_CHART_ROOT_PATH} ingress
sleep 3

: ${OSH_EXTRA_HELM_ARGS:=""}
tee /tmp/ingress-kube-system.yaml << EOF
deployment:
  mode: cluster
  type: DaemonSet
network:
  host_namespace: true
EOF

touch /tmp/ingress-component.yaml

if [ -n "${OSH_DEPLOY_MULTINODE}" ]; then
  tee --append /tmp/ingress-kube-system.yaml << EOF
pod:
  replicas:
    error_page: 2
EOF

  tee /tmp/ingress-component.yaml << EOF
pod:
  replicas:
    ingress: 2
    error_page: 2
EOF
fi

kubectl create ns openstack
kubectl create ns ceph
kubectl create ns nfs

kubectl label node kind-control-plane openstack-compute-node=enabled
kubectl label node kind-control-plane openstack-control-plane=enabled

helm upgrade --install ingress-kube-system ${HELM_CHART_ROOT_PATH}/ingress \
  --namespace=kube-system \
  --values=/tmp/ingress-kube-system.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS_KUBE_SYSTEM}
  
sleep 15

helm upgrade --install ingress-openstack ${HELM_CHART_ROOT_PATH}/ingress \
  --namespace=openstack \
  --values=/tmp/ingress-component.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS_OPENSTACK}

sleep 15

helm upgrade --install ingress-ceph ${HELM_CHART_ROOT_PATH}/ingress \
  --namespace=ceph \
  --values=/tmp/ingress-component.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS_CEPH}

sleep 15

make -C ${HELM_CHART_ROOT_PATH} nfs-provisioner
sleep 3

: ${OSH_INFRA_PATH:="../openstack-helm-infra"}
helm upgrade --install nfs-provisioner ${OSH_INFRA_PATH}/nfs-provisioner \
    --namespace=nfs \
    --set storageclass.name=general \
    ${OSH_EXTRA_HELM_ARGS_NFS_PROVISIONER}

sleep 15


: ${OSH_EXTRA_HELM_ARGS_MARIADB:="$(./tools/deployment/common/get-values-overrides.sh mariadb)"}
make -C ${HELM_CHART_ROOT_PATH} mariadb

sleep 3


#making pv for glance
tee /tmp/glance-pv.yaml <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: glance-pv
spec:
  storageClassName: general
  capacity:
    storage: 8Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/mnt/glance"
EOF

kubectl create -f /tmp/glance-pv.yaml

tee /tmp/glance-pv2.yaml <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: glance-pv2
spec:
  storageClassName: general
  capacity:
    storage: 8Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/mnt/glance"
EOF

kubectl create -f /tmp/glance-pv2.yaml



: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install mariadb ${HELM_CHART_ROOT_PATH}/mariadb \
    --namespace=openstack \
    --set volume.use_local_path_for_single_pod_cluster.enabled=true \
    --set volume.enabled=false \
    --values=/tmp/mariadb.yaml \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_MARIADB}

./tools/deployment/common/wait-for-pods.sh openstack

: ${OSH_EXTRA_HELM_ARGS_RABBITMQ:="$(./tools/deployment/common/get-values-overrides.sh rabbitmq)"}

make -C ${HELM_CHART_ROOT_PATH} rabbitmq
sleep 3

helm upgrade --install rabbitmq ${HELM_CHART_ROOT_PATH}/rabbitmq \
    --namespace=openstack \
    --set volume.enabled=false \
    --set pod.replicas.server=1 \
    ${OSH_EXTRA_HELM_ARGS:=} \
    ${OSH_EXTRA_HELM_ARGS_RABBITMQ}


./tools/deployment/common/wait-for-pods.sh openstack


: ${OSH_EXTRA_HELM_ARGS_MEMCACHED:="$(./tools/deployment/common/get-values-overrides.sh memcached)"}

make -C ${HELM_CHART_ROOT_PATH} memcached

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install memcached ${HELM_CHART_ROOT_PATH}/memcached \
    --namespace=openstack \
    ${OSH_EXTRA_HELM_ARGS:=} \
    ${OSH_EXTRA_HELM_ARGS_MEMCACHED}


./tools/deployment/common/wait-for-pods.sh openstack

make keystone

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install keystone ./keystone \
    --namespace=openstack \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_KEYSTONE}

./tools/deployment/common/wait-for-pods.sh openstack

: ${OSH_EXTRA_HELM_ARGS_HORIZON:="$(./tools/deployment/common/get-values-overrides.sh horizon)"}
: ${RUN_HELM_TESTS:="yes"}

#NOTE: Lint and package chart
make horizon

tee /tmp/Horizon-nodeport.yaml <<EOF
kind: Service
apiVersion: v1
metadata:
  name: horizon-nodeport
  namespace: openstack
spec:
  type: NodePort
  ports:
    - port: 80
      nodePort: 32020
  selector:
    application: horizon
    component: server
EOF

kubectl create -f /tmp/Horizon-nodeport.yaml



: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install horizon ./horizon \
    --namespace=openstack \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_HORIZON}

./tools/deployment/common/wait-for-pods.sh openstack


make glance

#NOTE: Get the over-rides to use
: ${OSH_EXTRA_HELM_ARGS_GLANCE:="$(./tools/deployment/common/get-values-overrides.sh glance)"}

tee /tmp/glance.yaml <<EOF
storage: pvc
pod:
  replicas:
    api: 1
    registry: 2
EOF


helm upgrade --install glance ./glance \
  --namespace=openstack \
  --values=/tmp/glance.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_GLANCE}

./tools/deployment/common/wait-for-pods.sh openstack

export OS_CLOUD=openstack_helm


: ${OSH_EXTRA_HELM_ARGS_OPENVSWITCH:="$(./tools/deployment/common/get-values-overrides.sh openvswitch)"}

make -C ${HELM_CHART_ROOT_PATH} openvswitch

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install openvswitch ${HELM_CHART_ROOT_PATH}/openvswitch \
  --namespace=openstack \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_OPENVSWITCH}

./tools/deployment/common/wait-for-pods.sh openstack

: ${OSH_EXTRA_HELM_ARGS_LIBVIRT:="$(./tools/deployment/common/get-values-overrides.sh libvirt)"}

make -C ${HELM_CHART_ROOT_PATH} libvirt

#NOTE: Deploy command
: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install libvirt ${HELM_CHART_ROOT_PATH}/libvirt \
  --namespace=openstack \
  --set conf.ceph.enabled=false \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_LIBVIRT}

export DEPLOY_SEPARATE_PLACEMENT="yes"

: ${OSH_EXTRA_HELM_ARGS_NOVA:="$(./tools/deployment/common/get-values-overrides.sh nova)"}


make nova


tee /tmp/nova.yaml << EOF
network:
  backend:
    - linuxbridge
pod:
  replicas:
    osapi: 1
    conductor: 1
    consoleauth: 1
bootstrap:
  wait_for_computes:
    enabled: true
conf:
  ceph:
    enabled: false
  nova:
    libvert:
      virt_type: qemu
      cpu_mode: none
EOF

helm upgrade --install nova ./nova \
      --namespace=openstack \
      --values=/tmp/nova.yaml \
      ${OSH_EXTRA_HELM_ARGS:=} \
      ${OSH_EXTRA_HELM_ARGS_NOVA}

: ${OSH_EXTRA_HELM_ARGS_NEUTRON:="$(./tools/deployment/common/get-values-overrides.sh neutron)"}

make neutron


tee /tmp/neutron.yaml << EOF
network:
  bakend:
    - linuxbridge
pod:
  replicas:
    server: 1
dependencies:
  dynamic:
    targeted:
      linuxbridge:
        dhcp:
          pod:
            - requireSameNode: true
              labels:
                application: neutron
                component: neutron-lb-agent
        l3:
          pod:
          - requireSameNode: true
            labels:
              application: neutron
              component: neutron-lb-agent
        metadata:
          pod:
            - requireSameNode: true
              labels:
                application: neutron
                component: neutron-lb-agent
        lb_agent:
          pod: null
conf:
  neutron:
    DEFAULT:
      interface_driver: linuxbridge
  dhcp_agent:
    DEFAULT:
      interface_driver: linuxbridge
  l3_agent:
    DEFAULT:
      interface_driver: linuxbridge
EOF


helm upgrade --install neutron ./neutron \
    --namespace=openstack \
    --values=/tmp/neutron.yaml \
    ${OSH_RELEASE_OVERRIDES_NEUTRON} \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_NEUTRON}

./tools/deployment/common/wait-for-pods.sh openstack




echo "now run the following commands in your terminal "
echo "------------------------------------------------"
echo "-- kubectl get nodes -o wide "
echo "and copy the ip of cluster and note it down"
echo "-- curl -L <your cluster ip>:32020"
echo "if it gives some output you are on the right path, Go onn"
echo "now open a new terminal and run ssh -L 32020:<clusterip>:32020 ubuntu@192.168.5.XXX"
echo "now open your browser and run localhost:32020"
echo "Thanks .........................................."

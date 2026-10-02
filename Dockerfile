FROM quay.io/operator-framework/ansible-operator:v1.42.2

COPY requirements.yml ${HOME}/requirements.yml
COPY requirements.txt ${HOME}/requirements.txt
RUN ansible-galaxy collection install -r ${HOME}/requirements.yml \
 && python3 -m pip install --no-cache-dir -r ${HOME}/requirements.txt \
 && chmod -R ug+rwx ${HOME}/.ansible

COPY watches.yaml ${HOME}/watches.yaml
COPY roles/ ${HOME}/roles/
COPY playbooks/ ${HOME}/playbooks/

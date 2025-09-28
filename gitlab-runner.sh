#!/usr/bin/env bash
######################################################
# gitlab-runner on K8s : Install by Helm chart
#
# https://gitlab.com/gitlab-org/gitlab-runner
# https://docs.gitlab.com/runner/install/kubernetes/
######################################################

# Images
variant=alpine3.21
version=17.11.3
arch=x86_64
export GLR_IMAGE_TAG="${variant}-v$version"
export GLR_IMAGE_REGISTRY='registry.gitlab.com'
export GLR_IMAGE_REPO='gitlab-org'
runner=$GLR_IMAGE_REGISTRY/$GLR_IMAGE_REPO/gitlab-runner:$GLR_IMAGE_TAG
helper=$GLR_IMAGE_REGISTRY/$GLR_IMAGE_REPO/gitlab-runner/gitlab-runner-helper:${variant}-${arch}-v$version

scan(){
    type -t trivy ||
        return 1

    trivy image --scanners vuln --severity CRITICAL,HIGH $runner |
        tee trivy.runner.cve.log

    trivy image --scanners vuln --severity CRITICAL,HIGH $helper |
        tee trivy.helper.cve.log
}

# Chart params
export GLR_HOST='gitlab.com'
export GLR_MANAGER='glr-manager'
export GLR_JOBS='glr-jobs'
repo=gitlab
chart=gitlab-runner
ver=0.76.3 # See search() for runner version per chart version
ns=$GLR_MANAGER
release=$chart
values=values.diff.yaml
secret=glrt-secret

export GLR_RBAC=rbac.$release.yaml

search(){
    # Available versions : chart v. runner
    helm search repo -l $repo/$chart |head
}

prep(){
    # Add repo
    helm repo update $repo ||
        helm repo update $repo
    
    # Pull chart to extract values.yaml
    helm pull $repo/$chart --version $ver &&
        tar -xaf ${chart}-$ver.tgz &&
            cp gitlab-runner/values.yaml . &&
                rm ${chart}-$ver.tgz ||
                    return 1
}

tkn(){
    secure(){
        [[ -f $secret.key.age ]] && {
            echo "EXISTS already"
            return 1
        }
        [[ $1 ]] && printf "$1" > $secret.key ||
            return 2

        type -t ageen &&
            ageen $seret.key &&
                rm $secret.key ||
                    return 3
    }

    get(){
        type -t agede > /dev/null 2>&1 &&
            agede $secret.key.age ||
                return 1
    }

    provision(){
        tkn="$(get)" ||
            return $?
        
        # Case 1. gitlab-runner on host
        type gitlab-runner &&
            gitlab-runner register --url https://$GLR_HOST --token $tkn

        # Case 2. gitlab-runner on K8s
        kubectl create ns $ns
        kubectl create secret generic $secret \
            --from-literal=runner-token="$tkn" \
            -n $ns
    }

    verify(){
        kubectl -n $ns get secret $secret -o jsonpath='{.data.runner-token}' |
            base64 -d
    }

    [[ $1 ]] || { type $FUNCNAME; return 0; }
    "$@"
}

template(){
    envsubst < $values.tpl > $values

    tkn="$(tkn get)" ||
        return 1

    # Generate declared state (YAML) at current $values
    helm template $release $repo/$chart --version $ver -n $ns \
        --values $values \
        --set runnerToken="$tkn" \
        |tee helm.template.yaml ||
            return 2
}

rbac(){
    # Apply RBAC for both Manager and Jobs
    
    kubectl get ns $GLR_MANAGER >/dev/null 2>&1 ||
        kubectl create ns $GLR_MANAGER

    kubectl get ns $GLR_JOBS >/dev/null 2>&1 ||
        kubectl create ns $GLR_JOBS

    kubectl apply -f $GLR_RBAC
}

up(){
    # Install/Upgrade
    tkn="$(tkn get)" ||
        return 1

    rbac
   
    # Install/Upgrade the chart
    helm upgrade $release $repo/$chart --install --version $ver -n $ns \
        --create-namespace \
        --values $values \
        --set runnerToken="$tkn" \
        --debug \
        --atomic \
        --timeout 2m \
        |tee helm.upgrade.log
}

manifest(){
    # Capture the running state
    helm get manifest $release -n $ns |tee helm.manifest.yaml
}

diffv(){
    diff values.yaml $values |grep -- '>'
}

diffs(){
    diff helm.template.yaml helm.manifest.yaml # declared v. running states
}

status(){
    kubectl get ${all:-pod} -l app=gitlab-runner -A
}

down(){
    # Teardown
    helm -n $GLR_MANAGER delete $release --wait &&
        kubectl delete ns $GLR_MANAGER $GLR_JOBS
}

[[ $1 ]] || { cat $BASH_SOURCE; exit 1; }

"$@" || echo "❌ ERR : $? at '${BASH_SOURCE##*/} $@'"

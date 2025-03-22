oc delete project quarkuscoffeeshop-demo

podman build -t quarkuscoffeeshop-image . 
podman run --platform linux/amd64 -it --env-file=./source.env quarkuscoffeeshop-image



oc delete all -l app=web
oc delete all -l app=kitchen
oc delete all -l app=barista
oc delete all -l app=counter

oc new-app ubi8/openjdk-17~https://github.com/nmushino/quarkuscoffeeshop-counter.git --name=counter --allow-missing-images --strategy=source

oc apply -f configmap/coffeeshop-configmap.yaml
oc apply -f configmap/counter-buildconfig.yaml

#oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-barista.git --name=barista --allow-missing-images --strategy=source
#oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-kitchen.git --name=kitchen --allow-missing-images --strategy=source
#oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-web.git --name=web --allow-missing-images --strategy=source


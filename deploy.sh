oc delete project quarkuscoffeeshop-demo

podman build -t quarkuscoffeeshop .
podman run --platform linux/amd64 -it --env-file=./source.env quarkuscoffeeshop

oc delete all -l app=web
oc delete all -l app=kitchen
oc delete all -l app=barista
oc delete all -l app=counter

oc apply -f configmap/coffeeshop-configmap.yaml -n quarkuscoffeeshop-demo

# counter app install
oc new-app ubi8/openjdk-17~https://github.com/nmushino/quarkuscoffeeshop-counter.git --name=counter --allow-missing-images --strategy=source -n quarkuscoffeeshop-demo
oc apply -f configmap/counter-development.yaml -n quarkuscoffeeshop-demo

# barista app install
oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-barista.git --name=barista --allow-missing-images --strategy=source -n quarkuscoffeeshop-demo
oc apply -f configmap/barista-development.yaml -n quarkuscoffeeshop-demo

# kitchen app install
oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-kitchen.git --name=kitchen --allow-missing-images --strategy=source -n quarkuscoffeeshop-demo
oc apply -f configmap/kitchen-development.yaml -n quarkuscoffeeshop-demo

# web app install
oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-web.git --name=web --allow-missing-images --strategy=source -n quarkuscoffeeshop-demo
oc apply -f configmap/web-development.yaml -n quarkuscoffeeshop-demo



oc expose deployment web --port=8080 --name=quarkuscoffeeshop-web
#oc expose deployment kitchen --port=8080 --name=quarkuscoffeeshop-web
#oc expose deployment barista --port=8080 --name=quarkuscoffeeshop-web
#oc expose deployment counter --port=8080 --name=quarkuscoffeeshop-web

oc expose svc/quarkuscoffeeshop-web
oc expose svc/quarkuscoffeeshop-customermocker
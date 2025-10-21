# Use the official lightweight Nginx image
FROM nginx:stable-alpine

# Copy the custom index.html into the default Nginx web root
COPY index.html /usr/share/nginx/html/index.html

# Expose the default HTTP port (80)
EXPOSE 80 

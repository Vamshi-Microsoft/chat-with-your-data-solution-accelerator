# AVM Post Deployment Guide

> **📋 Note**: This guide is specifically for post-deployment steps after using the AVM template. For complete deployment from scratch, see the main [deployment guide](../README.md).

---

This document provides guidance on post-deployment steps after deploying the Chat with your data - Solution accelerator from the [AVM (Azure Verified Modules) repository](https://github.com/Azure/bicep-registry-modules/tree/main/avm/ptn/sa/chat-with-your-data).

## Pre-requisites

Ensure you have a **Deployed Infrastructure** - A successful Chat with your data - Solution accelerator deployment from the [AVM repository](https://github.com/Azure/bicep-registry-modules/tree/main/avm/ptn/sa/chat-with-your-data)

## Post Deployment Steps

### Step 1: Run the Post-Deployment Setup Script

Run the post-deployment setup script to configure the Function App client key and create PostgreSQL tables (if applicable). Open [Azure Cloud Shell](https://shell.azure.com) (Bash) and run:

```bash
az login
git clone https://github.com/Azure-Samples/chat-with-your-data-solution-accelerator.git
cd chat-with-your-data-solution-accelerator
bash scripts/post_deployment_setup.sh "<your-resource-group-name>"
```

### Step 2: Build, Push, and Update Container Images (Container Model Only)

> **📌 Skip this step** if you deployed with the default `hostingModel=code`.

When deploying with `hostingModel=container`, the App Services start with a placeholder hello-world image. Run the combined container workflow to build and push the application images to your Azure Container Registry and update the App Services to use them.

**Run the combined ACR build/push/update script (remote build, no Docker required):**
```bash
bash scripts/acr_build_push_update.sh "<your-resource-group-name>"
```

> The script configures managed-identity based authentication between the App Services and your private ACR, then restarts all services. To build locally with Docker instead, use `--mode local`.

### Step 3: Configure App Authentication

1. After deployment is complete, navigate to your Azure App Service in the Azure portal
2. Follow the detailed instructions in [Set Up Authentication in Azure App Service](./azure_app_service_auth_setup.md) to add authentication to your web app
3. This will ensure only authorized users can access your application

### Step 4: Access and Configure the Admin Site

1. **Navigate to the admin site** using the following URL pattern:
   ```
   https://web-{unique-token}-admin.azurewebsites.net/
   ```

2. **Upload your documents**:
   - Select **Ingest Data** from the admin interface
   - Upload your documents using the drag-and-drop interface
   - For testing purposes, you can use the sample data located in the `/data` directory of this repository

   ![Admin site interface](./images/admin-site.png)

3. **Monitor the ingestion process**:
   - Wait for the documents to be processed and indexed
   - Verify successful ingestion through the admin interface

### Step 5: Access the Chat Application

1. **Navigate to the main chat application** using this URL pattern:
   ```
   https://web-{unique-token}.azurewebsites.net/
   ```

2. **Test the chat functionality**:
   - Start a conversation by asking questions about your uploaded documents
   - Verify that the AI responds with relevant information from your data

   ![Chat application interface](./images/web-unstructureddata.png)

## Next Steps

Consider these additional configurations for enhanced functionality:

- 📚 **[Advanced Image Processing](./advanced_image_processing.md)** - Enable enhanced document processing
- 🔄 **[Integrated Vectorization](./integrated_vectorization.md)** - Configure advanced AI search features
- 💬 **[Conversation Flow Options](./conversation_flow_options.md)** - Customize the chat experience
- 🎤 **[Speech-to-Text](./speech_to_text.md)** - Add voice interaction capabilities

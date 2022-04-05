public with sharing class RasaService extends ExternalNlpService {
    private final static String DEFAULT_LANGUAGE = 'en';

    // More Info here :
    private final static String API_VERSION = 'v2';
    private final static Map<String, String> LANGUAGE_CODE_MAP = new Map<String, String>{ 'en_US' => 'en' };

    /*
     * TODO: Update this help text
     *
     * To secure your Rasa endpoint, you should generate a secret key.
     * The authentication mechanism supports JWT-based authentication using a symmetric key for the signature.
     * The server can be started with this secret key and it will accept calls only if the JWT payload is verified using the secret key.
     *
     * TODO: It's assumed that asymmetric keys are only supported in Rasa X, the enterpise version for Rasa. For now we'll only support symmetric keys.
     * Documentation for Rasa Open Source specifies that you can specify an asymmetric key in the startup parameters (--jwt-secret),
     * but I have not gotten it to work. Changing the --jwt-method parameter to RS256 gives an error when trying to start up the Rasa server.
     *
     */

    // API Docs : https://rasa.com/docs/rasa/next/http-api
    public override List<HttpRequest> getPredictionRequests(
        ExternalNlpServiceParameters serviceParams,
        ExternalNlpPredictionRequestParameters params
    ) {
        // Retrieve session ID or generate a new one based on datetime
        String jwtToken = serviceParams.getAdditionalParams().get('jwt-token');

        // Build a new request for every set of ExternalNlpModelParameters
        List<HttpRequest> reqs = new List<HttpRequest>();

        for (ExternalNlpModelParameters modelParams : serviceParams.getModelParams()) {
            String endpoint = 'callout:' + modelParams.getNamedCredentialKey() + '/model/parse';

            // Create Map containing the structure of the JSON to send as body and serialize
            Map<String, Object> queryInputMap = new Map<String, Object>{ 'text' => params.getInput() };
            String body = JSON.serialize(queryInputMap);

            // Not needed
            // if (!serviceParams.getDisableSentimentDetection()) {
            //     queryInputMap.put(
            //         'queryParams',
            //         new Map<String, Object>{
            //             'sentimentAnalysisRequestConfig' => new Map<String, Object>{
            //                 'analyzeQueryTextSentiment' => true
            //             }
            //         }
            //     );
            // }

            // Build HTTP request and add to the list
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            if (body != null) {
                req.setBody(body);
            }
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Authorization', 'Bearer ' + jwtToken);
            reqs.add(req);
        }

        return reqs;
    }

    public override ExternalNlpPredictionResult getPredictionResult(
        ExternalNlpServiceParameters serviceParams,
        ExternalNlpPredictionResultParameters params
    ) {
        // Retrieve list of HTTP responses
        List<HttpResponse> responses = params.getHttpResponses();

        Map<String, ExternalNlpIntent> intentsMap = new Map<String, ExternalNlpIntent>();
        ExternalNlpIntent highestScoringExtIntent = null;
        Map<String, List<ExternalNlpEntity>> entitiesMap = new Map<String, List<ExternalNlpEntity>>();
        Map<String, ExternalNlpSentiment> sentimentsMap = new Map<String, ExternalNlpSentiment>();
        ExternalNlpSentiment highestScoringExtSentiment = null;

        // Check if the response was successful, and if so detect entities, intents, and sentiments
        for (HttpResponse response : responses) {
            if (response.getStatusCode() != 200) {
                throw new ExternalNlpServiceException(
                    'Received unexpected response code : ' + response.getStatusCode(),
                    ExternalNlpServiceExceptionCode.INVALID_HTTP_RESPONSE_CODE
                );
            }

            Map<String, Object> bodyMap = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());

            // Intent Detection
            highestScoringExtIntent = detectIntents(serviceParams, bodyMap, intentsMap, highestScoringExtIntent);

            // Named Entity Recognition
            detectEntities(serviceParams, bodyMap, entitiesMap);
        }

        // Create prediction result object instances for intent, entities and sentiment
        String highestConfidenceIntentName = null;
        if (
            highestScoringExtIntent != null &&
            highestScoringExtIntent.getConfidenceScore() >= serviceParams.getIntentThreshold()
        ) {
            highestConfidenceIntentName = highestScoringExtIntent.getName();
        }

        ExternalNlpPredictionIntentResult intentPredResult = new ExternalNlpPredictionIntentResult.Builder()
            .setHighestConfidenceIntentName(highestConfidenceIntentName)
            .setPredictedIntents(intentsMap)
            .build();

        ExternalNlpPredictionEntityResult entityPredResult = new ExternalNlpPredictionEntityResult.Builder()
            .setPredictedEntities(entitiesMap)
            .build();

        // Return prediction result object instance containing intent, entities and sentiment
        return new ExternalNlpPredictionResult.Builder()
            .setIntentResults(intentPredResult)
            .setEntityResults(entityPredResult)
            .build();
    }

    private ExternalNlpIntent detectIntents(
        ExternalNlpServiceParameters serviceParams,
        Map<String, Object> bodyMap,
        Map<String, ExternalNlpIntent> intentsMap,
        ExternalNlpIntent highestScoringExtIntent
    ) {
        if (serviceParams.getDisableIntentDetection()) {
            return highestScoringExtIntent;
        }

        Map<String, Object> responseIntentsMap = (Map<String, Object>) bodyMap.get('intent');

        if (responseIntentsMap != null && responseIntentsMap.get('name') != null) {
            Double intentDetectionConfidence = (Double) responseIntentsMap.get('confidence');
            String intentName = (String) responseIntentsMap.get('name');
            ExternalNlpIntent extIntent = new ExternalNlpIntent.Builder()
                .setName(intentName)
                .setConfidenceScore(intentDetectionConfidence)
                .build();
            intentsMap.put(intentName, extIntent);

            if (
                highestScoringExtIntent == null ||
                intentDetectionConfidence > highestScoringExtIntent.getConfidenceScore()
            ) {
                highestScoringExtIntent = extIntent;
            }
        }

        return highestScoringExtIntent;
    }

    private void detectEntities(
        ExternalNlpServiceParameters serviceParams,
        Map<String, Object> bodyMap,
        Map<String, List<ExternalNlpEntity>> entitiesMap
    ) {
        if (serviceParams.getDisableEntityExtraction()) {
            return;
        }

        List<Object> responseEntitiesList = (List<Object>) bodyMap.get('entities');

        if (responseEntitiesList == null) {
            return;
        }

        // Loop over all entities in the list
        for (Object responseEntity : responseEntitiesList) {
            Map<String, Object> responseEntityAttributeMap = (Map<String, Object>) responseEntity;
            String responseEntityName = (String) responseEntityAttributeMap.get('entity');
            String responseEntityValue = (String) responseEntityAttributeMap.get('value');
            Double responseEntityConfidence = (Double) responseEntityAttributeMap.get('confidence_entity');

            List<ExternalNlpEntity> extEntities = new List<ExternalNlpEntity>{
                new ExternalNlpEntity.Builder()
                    .setName(responseEntityName)
                    .setValue(responseEntityValue)
                    .setConfidenceScore(responseEntityConfidence)
                    .build()
            };
            entitiesMap.put(responseEntityName, extEntities);
        }
    }

    // public override String getNormalizedText(String value) {
    //     try {
    //         String normalizedTextValue = null;
    //         try {
    //             Map<String, Object> mapValue = (Map<String, Object>) JSON.deserializeUntyped(value);
    //             normalizedTextValue = (String) mapValue.get('name');
    //         } catch (System.JSONException je) {
    //             normalizedTextValue = value;
    //         } catch (System.TypeException te) {
    //             normalizedTextValue = value;
    //         }
    //         return normalizedTextValue;
    //     } catch (Exception e) {
    //         System.debug(e);
    //         throw new ExternalNlpServiceException(
    //             getNormalizationExceptionMessage(value, e),
    //             ExternalNlpServiceExceptionCode.NORMALIZED_VALUE_ERROR
    //         );
    //     }
    // }

    // public override DateTime getNormalizedDateTime(String value) {
    //     try {
    //         Map<String, Object> dateMap = (Map<String, Object>) JSON.deserializeUntyped(value);
    //         return (DateTime) JSON.deserialize('"' + dateMap.get('date_time') + '"', DateTime.class);
    //     } catch (Exception e) {
    //         try {
    //             return (DateTime) JSON.deserialize('"' + value + '"', DateTime.class);
    //         } catch (Exception e2) {
    //             throw new ExternalNlpServiceException(
    //                 getNormalizationExceptionMessage(value, e),
    //                 ExternalNlpServiceExceptionCode.NORMALIZED_VALUE_ERROR
    //             );
    //         }
    //     }
    // }
}

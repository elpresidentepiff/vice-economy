#pragma once

#include "CoreMinimal.h"
#include "HttpModule.h"
#include "Interfaces/IHttpRequest.h"
#include "Interfaces/IHttpResponse.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "EconomyManager.generated.h"

USTRUCT(BlueprintType)
struct VICEECONOMY_API FViceInventoryEntry
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    FString ItemId;

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    int32 Quantity = 0;
};

USTRUCT(BlueprintType)
struct VICEECONOMY_API FViceMarketItem
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    FString ItemId;

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    FString DisplayName;

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    FString Category;

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    int64 CurrentPrice = 0;
};

USTRUCT(BlueprintType)
struct VICEECONOMY_API FViceDistrictPrice
{
    GENERATED_BODY()

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    FString DistrictId;

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    FString ItemId;

    UPROPERTY(BlueprintReadOnly, Category = "Vice Economy")
    int64 CurrentPrice = 0;
};

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOnWalletUpdated, int64, CleanCash, int64, DirtyCash);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnInventoryUpdated, const TArray<FViceInventoryEntry>&, Items);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnMarketItemsUpdated, const TArray<FViceMarketItem>&, Items);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnDistrictPricesUpdated, const TArray<FViceDistrictPrice>&, Prices);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOnEconomyRequestFailed, FString, Operation, FString, ErrorMessage);

UCLASS()
class VICEECONOMY_API UEconomyManager : public UGameInstanceSubsystem
{
    GENERATED_BODY()

public:
    virtual void Initialize(FSubsystemCollectionBase& Collection) override;
    virtual void Deinitialize() override;

    UPROPERTY(BlueprintReadWrite, EditAnywhere, Category = "Vice Economy")
    FString SupabaseUrl = TEXT("https://ltbsxbvfsxtnharjvqcm.supabase.co");

    UPROPERTY(BlueprintReadWrite, EditAnywhere, Category = "Vice Economy")
    FString AnonKey;

    UFUNCTION(BlueprintCallable, Category = "Vice Economy")
    void SetUserJWT(const FString& JWT);

    UFUNCTION(BlueprintCallable, Category = "Vice Economy")
    void FetchWalletBalance();

    UFUNCTION(BlueprintCallable, Category = "Vice Economy")
    void FetchInventory();

    UFUNCTION(BlueprintCallable, Category = "Vice Economy")
    void FetchMarketItems();

    UFUNCTION(BlueprintCallable, Category = "Vice Economy")
    void FetchDistrictPrices(const FString& DistrictId);

    UFUNCTION(BlueprintCallable, Category = "Vice Economy")
    void BuyItem(const FString& ItemId, int32 Quantity);

    UFUNCTION(BlueprintCallable, Category = "Vice Economy")
    void StartLaundering(const FString& BusinessId, int64 Amount);

    UPROPERTY(BlueprintAssignable, Category = "Vice Economy")
    FOnWalletUpdated OnWalletUpdated;

    UPROPERTY(BlueprintAssignable, Category = "Vice Economy")
    FOnInventoryUpdated OnInventoryUpdated;

    UPROPERTY(BlueprintAssignable, Category = "Vice Economy")
    FOnMarketItemsUpdated OnMarketItemsUpdated;

    UPROPERTY(BlueprintAssignable, Category = "Vice Economy")
    FOnDistrictPricesUpdated OnDistrictPricesUpdated;

    UPROPERTY(BlueprintAssignable, Category = "Vice Economy")
    FOnEconomyRequestFailed OnRequestFailed;

private:
    FString UserJWT;

    FHttpRequestRef CreateRequest(const FString& Operation, const FString& Url, const FString& Verb, bool bRequiresJwt);
    void ApplyJsonHeaders(FHttpRequestRef Request, bool bRequiresJwt) const;
    void BroadcastFailure(const FString& Operation, FHttpResponsePtr Response, const FString& FallbackMessage);

    void OnFetchWalletResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess);
    void OnFetchInventoryResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess);
    void OnFetchMarketItemsResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess);
    void OnFetchDistrictPricesResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess);
    void OnBuyResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess);
    void OnLaunderResponse(FHttpRequestPtr Request, FHttpResponsePtr Response, bool bSuccess);
};

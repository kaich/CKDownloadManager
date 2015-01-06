//
//  CKDwonalodFileValidator.m
//  aisiweb
//
//  Created by mac on 14/12/16.
//  Copyright (c) 2014年 weiaipu. All rights reserved.
//

#import "CKDownloadFileValidator.h"
#import "CKDownloadPathManager.h"
#import "CKDownloadManager+MoveDownAndRetry.h"
#import "CKDownloadManager.h"

#ifndef URL
#define URL(_STR_) [NSURL URLWithString:_STR_]
#endif

#ifndef ORIGIN_URL
#define  ORIGIN_URL(_request_) _request_.originalURL ?  _request_.originalURL : _request_.url
#endif

@interface CKDownloadManager ()
/**
 *  update model change to database
 *
 *  @param model downlaod task model
 */
-(void) updateDataBaseWithModel:(id<CKDownloadModelProtocal>) model;

/**
 *  retry to download file when header file length is not equal to expect file length
 *
 *  @param url download url
 */
-(void) retryDownloadWhenHeaderErrorOcurWithURL:(NSURL *) url;

@end


@interface CKDownloadFileValidator ()
@property(nonatomic,strong) NSMutableDictionary * currentRetryCountDic;
@end

@implementation CKDownloadFileValidator

-(instancetype) init
{
    self = [super init];
    if(self)
    {
        self.currentRetryCountDic=[NSMutableDictionary dictionary];
    }
    return self;
}

-(void) validateFileSizeWithModel:(id<CKValidatorModelProtocal,CKDownloadModelProtocal>) model completeBlock:(DownloadFileValidateCompleteBlock) completeBlock
{
    if(model)
    {
        
        BOOL isSuccessful=YES;
        long long standardValue = model.standardFileSize;
        long long currentValue = [CKDownloadPathManager downloadContentSizeWithURL:URL(model.URLString)];
        if( currentValue != standardValue  &&  standardValue != 0)
        {
            model.downloadContentSize = @"0";
            model.restTime = @"0";
            model.speed = @"0";
            [CKDownloadPathManager removeFileWithURL:URL(model.URLString)];
            [self.downloadManager pauseWithURL:URL(model.URLString)];
            model.downloadState= kDSDownloadErrorFinalLength;
            [self.downloadManager updateDataBaseWithModel:model];
            
            
            isSuccessful =NO;
        }
        
        if(completeBlock)
        {
            completeBlock(model,model,isSuccessful);
        }
    }
}


-(void) validateFileContentWithModel:(id<CKValidatorModelProtocal,CKDownloadModelProtocal>) model completeBlock:(DownloadFileValidateCompleteBlock) completeBlock
{
    if(model)
    {
        dispatch_async(dispatch_get_global_queue(0, 0), ^(void) {
            __block BOOL isSuccessful=YES;
            if(model.standardFileValidationCode==nil || model.standardFileValidationCode.length == 0  || [model.standardFileValidationCode isEqualToString:@"0"])
            {
                isSuccessful=YES;
            }
            else
            {
                
                    NSTimeInterval  beforeValidateTime =[NSDate timeIntervalSinceReferenceDate];
                    
                    NSString * resultString =[self generateValidateCodeWithURL:URL(model.URLString)];
                    
                    NSTimeInterval  afterValiteTime =[NSDate timeIntervalSinceReferenceDate];
                    NSTimeInterval  interval = afterValiteTime -beforeValidateTime;
                    
                    
                    NSLog(@"%f",interval);
                    NSLog(@"%@",resultString);
                    
                    //if not equal , send log
                    if(![resultString isEqualToString:[model.standardFileValidationCode uppercaseString]])
                    {
                        
                        model.downloadContentSize = @"0";
                        model.restTime = @"0";
                        model.speed = @"0";
                        
                        [CKDownloadPathManager removeFileWithURL:URL(model.URLString)];
                        [self.downloadManager pauseWithURL:URL(model.URLString)];
                        model.downloadState = kDSDownloadErrorContent;
                        [self.downloadManager updateDataBaseWithModel:model];
                        
                        isSuccessful=NO;
                    }
                    else
                    {
                        isSuccessful=YES;
                    }
                
            }
            
            if(completeBlock)
            {
                completeBlock(model,model,isSuccessful);
            }
            
        });
    }

}


-(void) validateFileHeaderWithModel:(id<CKValidatorModelProtocal,CKDownloadModelProtocal>) model headerFileLength:(long long) fileLength times:(NSUInteger) times completeBlock:(DownloadFileValidateCompleteBlock) completeBlock
{
    BOOL isSuccessful = YES;
    if(fileLength != model.standardFileSize )
    {
        
        int count =[[self.currentRetryCountDic objectForKey:URL(model.URLString)] intValue];
        int nextCount =count+1;
        if(nextCount > 5)
        {
            model.downloadContentSize = @"0";
            model.restTime = @"0";
            model.speed = @"0";
            [self.downloadManager pauseWithURL:URL(model.URLString)];
            [self.currentRetryCountDic setObject:[NSNumber numberWithInt:0] forKey:URL(model.URLString)];
            model.downloadState  = kDSDownloadErrorResum;
            [self.downloadManager updateDataBaseWithModel:model];
            
            isSuccessful = NO;
        }
        else
        {
            [self.currentRetryCountDic setObject:[NSNumber numberWithInt:nextCount] forKey:URL(model.URLString)];
            [self.downloadManager retryDownloadWhenHeaderErrorOcurWithURL:URL(model.URLString)];
        }
    }
    else
    {
        [self.currentRetryCountDic setObject:[NSNumber numberWithInt:0] forKey:URL(model.URLString)];
        isSuccessful = YES ;
    }
    
    if(completeBlock)
    {
        completeBlock(model,model,isSuccessful);
    }

}



#pragma mark - private method
/**
 *  hex to hex string
 *
 *  @param bytes  bytes
 *  @param length bytes length
 *
 *  @return hex string
 */
-(NSString *) hexStringFromBytes:(Byte * ) bytes length:(NSUInteger) length
{
    NSString *hexStr=@"";
    for(int i=0;i<length;i++)
    {
        NSString *newHexStr = [NSString stringWithFormat:@"%x",bytes[i]&0xff]; ///16进制数
        if([newHexStr length]==1)
            hexStr = [NSString stringWithFormat:@"%@0%@",hexStr,newHexStr];
        else
            hexStr = [NSString stringWithFormat:@"%@%@",hexStr,newHexStr];
    }
    return  [hexStr uppercaseString];
}

/**
 *  generate validate code string
 *
 *  @param url download task url
 *
 *  @return validate code string
 */
-(NSString *) generateValidateCodeWithURL:(NSURL*) url
{
    NSString * finalPath=nil;
    NSString * tmpPath=nil;
    [CKDownloadPathManager SetURL:url toPath:&finalPath tempPath:&tmpPath];
    
    
    NSFileManager *fileManager = [NSFileManager new];
    
    
    NSString * resultString = @"";
    if ([fileManager fileExistsAtPath:finalPath])
    {
        
        NSUInteger readPointer = 0;
        const NSUInteger buffSize =  16384*16;
        Byte * buff =malloc(buffSize);
        NSUInteger  realChunkSize =0;
        Byte  currentByte=0;
        Byte  vBuff[8];
        
        NSUInteger i = 0;
        NSUInteger j = 0;
        memset(vBuff, 0x00, 8);
        
        
        NSUInteger fileSize =[CKDownloadPathManager downloadContentSizeWithURL:url];
        
        FILE *  file = fopen([finalPath cStringUsingEncoding:NSUTF8StringEncoding], "r");
        if(file)
        {
            while(readPointer < fileSize)
            {
                NSUInteger distanceToEndOfData = fileSize - readPointer;
                
                realChunkSize = (distanceToEndOfData > buffSize ? buffSize : distanceToEndOfData);
                
                fread(buff, 1, realChunkSize, file);
                
                
                for (j=0; j<64; j+=8){
                    currentByte=0;
                    for (i =j; i< realChunkSize ; i+=64) {
                        vBuff[j/(8)]= vBuff[j/(8)] ^ buff[i];
                    }
                    
                }
                
                readPointer += realChunkSize;
                
            }
            fclose(file);
        }
        
        resultString =[self hexStringFromBytes:vBuff length:8];
    }
    
   
    return resultString;
}
@end

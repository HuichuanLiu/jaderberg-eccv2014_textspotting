/** @file gconv.cu
 ** @brief Convolution block
 ** @author Andrea Vedaldi
 **/

#include "mex.h"
#ifdef ENABLE_GPU
#include "gpu/mxGPUArray.h"
#endif
#include "bits/mexutils.h"
#include "bits/im2col.hpp"

#include <blas.h>
#include <iostream>
#include <assert.h>

#ifdef ENABLE_GPU
#include <cublas_v2.h>
#endif

/* option codes */
enum {
    opt_stride = 0,
    opt_pad,
    opt_verbose
} ;

/* options */
vlmxOption  options [] = {
    {"Stride",           1,   opt_stride            },
    {"Pad",              1,   opt_pad               },
    {"Verbose",          0,   opt_verbose           },
    {0,                  0,   0                     }
} ;

enum {
    IN_DATA = 0, IN_FILTERS1, IN_FILTERS2, IN_DER, IN_END
} ;

enum {
    OUT_RESULT = 0, OUT_RESULT2, OUT_END
} ;

void mexFunction(int nout, mxArray *out[],
                 int nin, mxArray const *in[])
{
    mxClassID dataClassID ;
    mxClassID filters1ClassID, filters2ClassID ; ;
    mxClassID derClassID ;
    
    mxArray *resultArray ;
    mxArray *dfiltersArray ;
    mxArray *tempArray ;
    mxArray *temp1Array ;
    mxArray *res1Array;
    
    size_t height, width, depth, numImages, numOut ;
    size_t filter1Height, filter1Width, numFilters1, filter2Height, filter2Width, numFilters2 ;
    size_t derHeight, derWidth, derDepth, numDerImages ;
    int stride = 1 ;
    int pad = 0 ;
    mwSize dataNumDimensions ;
    mwSize filters1NumDimensions, filters2NumDimensions ;
    mwSize derNumDimensions ;
    mwSize const * dataDimensions ;
    mwSize const * filters1Dimensions ;
    mwSize const * filters2Dimensions ;
    mwSize const * derDimensions ;
    mwSize resultDimensions [4] ;
    mwSize dfiltersDimensions [4] ;
    mwSize tempDimensions [3] ;
    mwSize temp1Dimensions [3] ;
    mwSize res1Dimensions[3] ;
    
    
    bool const gpuMode = false ;
    bool backMode = false ;
    
    int verbosity = 0 ;
    int opt ;
    int next = IN_END ;
    mxArray const *optarg ;
    
    
    /* -------------------------------------------------------------- */
    /*                                            Check the arguments */
    /* -------------------------------------------------------------- */
    
    if (nin < 3) {
        mexErrMsgTxt("The arguments are less than three.") ;
    }
    
    if (nin > 3 && vlmxIsString(in[3],-1)) {
        next = 3 ;
        backMode = 0 ;
    } else {
        backMode = (nin >= 4) ;
    }
    
    while ((opt = vlmxNextOption (in, nin, options, &next, &optarg)) >= 0) {
        switch (opt) {
            case opt_verbose :
                ++ verbosity ;
                break ;
                
            case opt_stride :
                if (!vlmxIsPlainScalar(optarg) || (stride = (int) *mxGetPr(optarg)) < 1) {
                    mexErrMsgTxt("STRIDE must be a positive integer.") ;
                }
                break ;
                
            case opt_pad :
                if (!vlmxIsPlainScalar(optarg) || (pad = (int) *mxGetPr(optarg)) < 0) {
                    mexErrMsgTxt("PAD must be a non-negative integer.") ;
                }
                break ;
                
            default: break ;
        }
    }
    
    
    if (!mxIsNumeric(in[IN_DATA])) {
        mexErrMsgTxt("DATA must be numeric (note: GPU support not compiled).") ;
    }
    
    if (gpuMode) {
        assert(false) ;
    } else {
        if (!mxIsNumeric(in[IN_FILTERS1])) {
            mexErrMsgTxt("DATA is a CPU array but FILTERS1 is not.") ;
        }
        if (!mxIsNumeric(in[IN_FILTERS2])) {
            mexErrMsgTxt("DATA and FILTERS1 are CPU arrays but FILTERS2 is not.") ;
        }
        dataClassID = mxGetClassID(in[IN_DATA]) ;
        dataNumDimensions = mxGetNumberOfDimensions(in[IN_DATA]) ;
        dataDimensions = mxGetDimensions(in[IN_DATA]) ;
        filters1ClassID = mxGetClassID(in[IN_FILTERS1]) ;
        filters2ClassID = mxGetClassID(in[IN_FILTERS2]) ;
        filters1NumDimensions = mxGetNumberOfDimensions(in[IN_FILTERS1]) ;
        filters2NumDimensions = mxGetNumberOfDimensions(in[IN_FILTERS2]) ;
        filters1Dimensions = mxGetDimensions(in[IN_FILTERS1]) ;
        filters2Dimensions = mxGetDimensions(in[IN_FILTERS2]) ;
        if (backMode) {
            derClassID = mxGetClassID(in[IN_DER]) ;
            derNumDimensions = mxGetNumberOfDimensions(in[IN_DER]) ;
            derDimensions = mxGetDimensions(in[IN_DER]) ;
        }
    }
    
    if (dataClassID != mxSINGLE_CLASS) {
        mexErrMsgTxt("DATA is not of class SINGLE.");
    }
    if (filters1ClassID != mxSINGLE_CLASS) {
        mexErrMsgTxt("FILTERS1 is not of class SINGLE.");
    }
    if (filters2ClassID != mxSINGLE_CLASS) {
        mexErrMsgTxt("FILTERS2 is not of class SINGLE.");
    }
    if (backMode && (derClassID != mxSINGLE_CLASS)) {
        mexErrMsgTxt("DER is not of class SINGLE.");
    }
    
    height = dataDimensions[0] ;
    width = dataDimensions[1] ;
    switch (dataNumDimensions) {
        case 2 : depth = 1 ; numImages = 1 ; break ;
        case 3 : depth = dataDimensions[2] ; numImages = 1 ; break ;
        case 4 : depth = dataDimensions[2] ; numImages = dataDimensions[3] ; break ;
        default:  mexErrMsgTxt("DATA has neither two, three nor four dimensions.") ; break ;
    }
    
    filter1Height = filters1Dimensions[0] ;
    filter1Width = filters1Dimensions[1] ;
    filter2Height = filters2Dimensions[0] ;
    filter2Width = filters2Dimensions[1] ;
    if (filters1NumDimensions != filters2NumDimensions) {
        mexErrMsgTxt("FILTERS1 and FILTERS2 do not have the same number of dimensions.");
    }
    switch (filters1NumDimensions) {
        case 2 : numFilters1 = 1 ; numFilters2 = 1 ; break ;
        case 3 : numFilters1 = filters1Dimensions[2] ; numFilters2 = filters2Dimensions[2] ; break ;
        default:  mexErrMsgTxt("FILTERS1 and FILTERS2 have neither two nor three dimensions.") ; break ;
    }
    
    if (backMode) {
        derHeight = derDimensions[0] ;
        derWidth = derDimensions[1] ;
        switch (derNumDimensions) {
            case 2 : derDepth = 1 ; numDerImages = 1 ; break ;
            case 3 : derDepth = derDimensions[2] ; numDerImages = 1 ; break ;
            case 4 : derDepth = derDimensions[2] ; numDerImages = derDimensions[3] ; break ;
            default:  mexErrMsgTxt("DER has neither two, three, nor four dimensions.") ; break ;
        }
    }
    
    
    /* check the two filterbanks correspond */
    if (numFilters1 != numFilters2) {
        mexErrMsgTxt("FILTERS1 and FILTERS2 do not have the same number of filters.");
    }
    
    
    numOut = depth*numFilters1 ;
    
    temp1Dimensions[0] = (height + 2*pad - filter1Height)/stride + 1 ;
    temp1Dimensions[1] = (width + 2*pad - filter1Width)/stride + 1 ;
    temp1Dimensions[2] = filter1Height*filter1Width ;
    
    if (!backMode) {
        res1Dimensions[0] = temp1Dimensions[0];
        res1Dimensions[1] = temp1Dimensions[1];
        res1Dimensions[2] = numFilters1;
        resultDimensions[0] = (temp1Dimensions[0] + 2*pad - filter2Height)/stride + 1 ;
        resultDimensions[1] = (temp1Dimensions[1] + 2*pad - filter2Width)/stride + 1 ;
        resultDimensions[2] = numOut;
        resultDimensions[3] = numImages;
    } else {
        resultDimensions[0] = height ;
        resultDimensions[1] = width ;
        resultDimensions[2] = depth ;
        resultDimensions[3] = numImages ;
        dfiltersDimensions[0] = filter1Height ;
        dfiltersDimensions[1] = filter1Width ;
        dfiltersDimensions[2] = 1 ;
        dfiltersDimensions[3] = numFilters1 ;
    }
    
    tempDimensions[0] = (temp1Dimensions[0] + 2*pad - filter2Height)/stride + 1 ;
    tempDimensions[1] = (temp1Dimensions[1] + 2*pad - filter2Width)/stride + 1 ;
    tempDimensions[2] = filter2Height*filter2Width ;
    
    /* temp1 is for first filter, temp2 is for 2nd filter */
    
    if (verbosity > 0) {
        double const MB = 1024.0*1024.0 ;
        mexPrintf("gconv: mode %s; %s\n", gpuMode?"gpu":"cpu", backMode?"backward":"forward") ;
        mexPrintf("gconv: stride: %d, pad: %d\n", stride, pad) ;
        mexPrintf("gconv: data: %d x %d x %d x %d [%.1f MB]\n",
                  height, width, depth, numImages,
                  (double)(height*width*depth*numImages*4)/MB) ;
        mexPrintf("gconv: filters1: %d x %d x %d [%.1f MB]\n",
                  filter1Height, filter1Width, numFilters1,
                  (double)(filter1Height*filter1Width*numFilters1*4)/MB) ;
        mexPrintf("gconv: filters2: %d x %d x %d [%.1f MB]\n",
                  filter2Height, filter2Width, numFilters2,
                  (double)(filter2Height*filter2Width*numFilters2*4)/MB) ;
        mexPrintf("gconv: res1: %d x %d x %d [%.1f MB]\n",
                  res1Dimensions[0], res1Dimensions[1], res1Dimensions[2],
                  (double)(res1Dimensions[0]*res1Dimensions[1]*4)/MB) ;
        mexPrintf("gconv: result: %d x %d x %d x %d [%.1f MB]\n",
                  resultDimensions[0], resultDimensions[1], resultDimensions[2], resultDimensions[3],
                  (double)(resultDimensions[0]*resultDimensions[1]*resultDimensions[2]*resultDimensions[3]*4)/MB) ;
        if (backMode) {
            mexPrintf("gconv: der: %d x %d x %d x %d [%.1f MB]\n",
                      derHeight, derWidth, derDepth, numDerImages,
                      (double)(derHeight*derWidth*derDepth*numDerImages*4)/MB) ;
            mexPrintf("gconv: dfilters: %d x %d x %d x %d [%.1f MB]\n",
                      dfiltersDimensions[0], dfiltersDimensions[1], dfiltersDimensions[2], dfiltersDimensions[3],
                      (double)(dfiltersDimensions[0]*dfiltersDimensions[1]*dfiltersDimensions[2]*dfiltersDimensions[3]*4)/MB) ;
        }
        mexPrintf("gconv: temp1: %d x %d x %d [%.1f MB]\n",
                  temp1Dimensions[0], temp1Dimensions[1], temp1Dimensions[2],
                  (double)(temp1Dimensions[0]*temp1Dimensions[1]*temp1Dimensions[2]*4)/MB) ;
        mexPrintf("gconv: temp: %d x %d x %d [%.1f MB]\n",
                  tempDimensions[0], tempDimensions[1], tempDimensions[2],
                  (double)(tempDimensions[0]*tempDimensions[1]*tempDimensions[2]*4)/MB) ;
    }
    
    
    if (backMode) {
        if (derHeight != tempDimensions[0] ||
            derWidth != tempDimensions[1] ||
            derDepth != numFilters1 ||
            numDerImages != numImages)
        {
            mexErrMsgTxt("DER dimensions are incompatible with X and FILTERS.") ;
        }
    }
    
    if (height < filter1Height ||  width < filter1Width) {
        mexErrMsgTxt("FILTERS1 are larger than the DATA.") ;
    }
    if (temp1Dimensions[0] < filter2Height ||  temp1Dimensions[1] < filter2Width) {
        mexErrMsgTxt("FILTERS2 are larger than the DATA.") ;
    }
    
    if (filter1Height == 0 || filter1Width == 0 || filter2Height == 0 || filter2Width == 0) {
        mexErrMsgTxt("A dimension of FILTERS is void.") ;
    }
    
    /* -------------------------------------------------------------- */
    /*                                                    Do the work */
    /* -------------------------------------------------------------- */
    
    if (gpuMode) {
        assert(false) ;
    } else {
        tempArray = mxCreateNumericArray(3, tempDimensions,
                                         mxSINGLE_CLASS,
                                         mxREAL) ;
        temp1Array = mxCreateNumericArray(3, temp1Dimensions,
                                          mxSINGLE_CLASS,
                                          mxREAL) ;
        if (!backMode) {
            res1Array = mxCreateNumericArray(3, res1Dimensions,
                                             mxSINGLE_CLASS,
                                             mxREAL) ;
        }
        
        resultDimensions[3] += 1;
            resultArray = mxCreateNumericArray(4, resultDimensions,
                                               mxSINGLE_CLASS,
                                               mxREAL) ;
        resultDimensions[3] -= 1;
        
        if (backMode) {
            dfiltersArray = mxCreateNumericArray(4, dfiltersDimensions,
                                                 mxSINGLE_CLASS,
                                                 mxREAL);
        }
    }

    for (int image = 0 ; image < numImages ; ++image) {
        for (int channel = 0; channel < depth ; ++channel) {
            
            ptrdiff_t dataImOffset = (width*height*depth) * image ;
            ptrdiff_t dataChanOffset = width * height * channel ;
            ptrdiff_t resImOffset = (resultDimensions[0]*resultDimensions[1]*resultDimensions[2]) * image ;
            ptrdiff_t derImOffset = (tempDimensions[0]*tempDimensions[1]*numFilters1) * image ;
            ptrdiff_t m2 = tempDimensions[0]*tempDimensions[1] ; /* num output pixels */
            ptrdiff_t m1 = temp1Dimensions[0]*temp1Dimensions[1] ; /* num output pixels */
            ptrdiff_t n = numFilters1 ; /* num filters per group */
            ptrdiff_t k1 = filter1Height*filter1Width ; /* filter volume */
            ptrdiff_t k2 = filter2Height*filter2Width ; /* filter volume */
            char OP_N = 'n' ;
            char OP_T = 't' ;
            
            if (backMode) {
                /* ---------------------------------------------------------- */
                /*                                              Backward mode */
                /* ---------------------------------------------------------- */
                assert(false);
            } else {
                /* ---------------------------------------------------------- */
                /*                                               Forward mode */
                /* ---------------------------------------------------------- */
                
                //mexPrintf("1\n");
                
                /* FILTER 1 */
                if (gpuMode) {
                    assert(false);
                } else {
                    im2col_cpu<float>((float const*)mxGetData(in[IN_DATA]) + dataImOffset + dataChanOffset,
                                      1, width, height,
                                      filter1Width, filter1Height,
                                      stride, pad,
                                      (float *)mxGetData(temp1Array)) ;
                }
                
                //mexPrintf("2\n");
                
                float alpha = 1 ;
                float beta = 0 ;
                if (gpuMode) {
                    assert(false) ;
                } else {
                    sgemm(&OP_N, &OP_N,
                          &m1, &n, &k1,
                          &alpha,
                          (float*)mxGetData(temp1Array), &m1,
                          (float*)mxGetData(in[IN_FILTERS1]), &k1,
                          &beta,
                          (float*)mxGetData(res1Array), &m1) ;
                }
                
                
                
                /* FILTER 2s */
                for (int filter = 0 ; filter < numFilters2 ; ++filter) {
                    /* convolve the 2nd part of each filter individually */
                    ptrdiff_t res1ChanOffset = res1Dimensions[0]*res1Dimensions[1]*filter;
                    ptrdiff_t filterOffset = filter2Width*filter2Height*filter;
                    ptrdiff_t resChanOffset = resultDimensions[0]*resultDimensions[1] * (channel*numFilters2 + filter);
                    
                    //mexPrintf("3\n");
                    
                    if (gpuMode) {
                        assert(false);
                    } else {
                        im2col_cpu<float>((float const*)mxGetData(res1Array) + res1ChanOffset,
                                          1, res1Dimensions[1], res1Dimensions[0],
                                          filter2Width, filter2Height,
                                          stride, pad,
                                          (float *)mxGetData(tempArray)) ;
                    }
                    
                    //mexPrintf("4) %d %d %d %d %d %d %d\n", image, channel, m2, n, k2, filterOffset, resImOffset + resChanOffset);
                    
                    if (gpuMode) {
                        assert(false) ;
                    } else {
                        sgemm(&OP_N, &OP_N,
                              &m2, &n, &k2,
                              &alpha,
                              (float*)mxGetData(tempArray), &m2,
                              (float*)mxGetData(in[IN_FILTERS2]) + filterOffset, &k2,
                              &beta,
                              (float*)mxGetData(resultArray) + resImOffset + resChanOffset, &m2) ;
                    }
                    //mexPrintf("5\n");
                }
                
            }
        }
    }
    
    
    /* -------------------------------------------------------------- */
    /*                                                        Cleanup */
    /* -------------------------------------------------------------- */
    if (gpuMode) {
        assert(false) ;
    } else {
        mxDestroyArray(tempArray);
        mxDestroyArray(temp1Array);
        mxDestroyArray(res1Array);
        if (backMode) {
            out[OUT_RESULT] = dfiltersArray ;
            if (nout > 1) { out[OUT_RESULT2] = resultArray ; }
        } else {
            out[OUT_RESULT] = resultArray ;
        }
    }
}
